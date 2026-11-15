import time

import pytest

from atomhealth import activity, app as appmod, sync

db = appmod.db
TABLES = ("readings", "meals", "meal_items", "sync_outbox", "sync_versions", "sync_links", "sync_log",
          "activity_days", "nutrition_days", "workouts")


@pytest.fixture(autouse=True)
def clean():
    for t in TABLES:
        db.execute(f"DELETE FROM {t}")
    db.commit()
    yield


def env(type_, id_, version, **data):
    return {"v": 1, "type": type_, "op": "upsert", "id": id_, "version": version, "updated_at": 0, "data": data}


def day(offset=0):
    return time.strftime("%Y-%m-%d", time.localtime(time.time() - offset * 86400))


def test_workout_type_numbers_and_names():
    assert activity.workout_type("37") == ("Running", "cardio")
    assert activity.workout_type(52) == ("Walking", "outdoor")
    assert activity.workout_type("running") == ("Running", "cardio")
    assert activity.workout_type("3000") == ("Other", "other")
    assert activity.workout_type("99999") == ("Workout", "other")
    assert activity.workout_type(None) == ("Workout", "other")
    assert activity.workout_type("someNewKind")[0] == "Some new kind"


def test_empty_feed():
    f = activity.feed(db)
    assert f["days"] == [] and f["workouts"] == [] and f["updated"] is None


def test_feed_joins_days_workouts_and_intake():
    now = time.time()
    start = int(now) - 7200
    sync.apply_batch(db, [
        env("activity_day", f"day:{day(1)}", 1, day=day(1), active_kcal=640.4, basal_kcal=1700, steps=9100),
        env("activity_day", f"day:{day(0)}", 1, day=day(0), active_kcal=100, basal_kcal=400, steps=800),
        env("nutrition_day", f"day:{day(1)}", 1, day=day(1), kcal=300),
        env("workout", "w-1", 1, start_ts=start, end_ts=start + 1800, type="37", kcal=300.6, distance_m=5000),
        env("workout", "w-2", 1, start_ts=start - 86400, type="traditionalStrengthTraining"),
    ])
    meal_ts = int(now) - 86400
    db.execute("INSERT INTO meals(ts,kcal,status) VALUES(?,?,?)", (meal_ts, 800, "confirmed"))
    db.execute("INSERT INTO meals(ts,kcal,status) VALUES(?,?,?)", (meal_ts, 999, "pending"))
    db.commit()
    f = activity.feed(db, now)
    assert [d["day"] for d in f["days"]] == [day(1), day(0)] and f["today"] == day(0)
    y = f["days"][0]
    assert (y["active_kcal"], y["basal_kcal"], y["steps"], y["other_kcal"]) == (640, 1700, 9100, 300)
    assert y["logged_kcal"] == 800      # pending meals are not counted
    assert "logged_kcal" not in f["days"][1]
    w = f["workouts"]
    assert [x["id"] for x in w] == ["w-1", "w-2"]           # newest first
    assert (w[0]["type"], w[0]["group"], w[0]["minutes"], w[0]["kcal"], w[0]["km"]) == ("Running", "cardio", 30, 301, 5.0)
    assert w[1]["minutes"] is None and w[1]["kcal"] is None and w[1]["km"] is None
    assert f["updated"] is not None


def test_state_endpoint_includes_activity():
    import asyncio
    from aiohttp.test_utils import TestClient, TestServer

    async def go():
        async with TestClient(TestServer(appmod.make_app(False, True))) as c:
            r = await c.get("/api/state")
            return await r.json()
    sync.apply_batch(db, [env("activity_day", f"day:{day(0)}", 1, day=day(0), steps=1234)])
    st = asyncio.run(go())
    assert st["activity"]["days"][0]["steps"] == 1234
