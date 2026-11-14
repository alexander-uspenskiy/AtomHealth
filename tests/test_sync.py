import asyncio
import time

import pytest
from aiohttp.test_utils import TestClient, TestServer

from atomhealth import app as appmod, food, sync

db = appmod.db
TABLES = ("readings", "meals", "meal_items", "sync_outbox", "sync_versions", "sync_links", "sync_log",
          "activity_days", "nutrition_days", "workouts")


@pytest.fixture(autouse=True)
def clean():
    for t in TABLES:
        db.execute(f"DELETE FROM {t}")
    db.commit()
    yield


def env(type_, id_, version, op="upsert", **data):
    return {"v": 1, "type": type_, "op": op, "id": id_, "version": version, "updated_at": 0, "data": data or None}


def reading(source="scale", w=70.0, ts=None):
    rid = appmod.add_reading(w, ts or time.time(), source=source)
    return db.execute("SELECT * FROM readings WHERE id=?", (rid,)).fetchone()


def meal(status="confirmed", kcal=500):
    analysis = {"is_food": True, "meal_type": "lunch", "confidence": 0.9, "notes": "", "adjusted": [],
                "totals": {"kcal": kcal, "protein_g": 30, "carbs_g": 50, "fat_g": 10, "fiber_g": 5},
                "items": [{"name": "rice", "grams": 150, "kcal": kcal, "protein_g": 30, "carbs_g": 50, "fat_g": 10, "fiber_g": 5}]}
    mid = food.store_meal(db, analysis, photos=None, caption="lunch")
    if status != "pending":
        food.set_status(db, mid, status)
    return mid


def test_migrate_is_idempotent_and_triggers_exist():
    before = db.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger'").fetchone()[0]
    sync.migrate(db)
    sync.migrate(db)
    assert db.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger'").fetchone()[0] == before >= 9


def test_new_reading_gets_sync_id_and_is_queued():
    r = reading()
    assert r["sync_id"] and len(r["sync_id"]) == 32
    q = db.execute("SELECT type, sync_id FROM sync_outbox").fetchall()
    assert [(x["type"], x["sync_id"]) for x in q] == [("weight", r["sync_id"])]


def test_collect_coalesces_edits_and_versions_increase():
    r = reading()
    db.execute("UPDATE readings SET weight=71 WHERE id=?", (r["id"],))
    db.execute("UPDATE readings SET weight=72 WHERE id=?", (r["id"],))
    db.commit()
    envs, nxt = sync.collect(db, 0)
    assert len(envs) == 1 and envs[0]["op"] == "upsert" and envs[0]["data"]["weight_kg"] == 72
    assert nxt == sync.outbox_max(db)
    sync.mark_sent(db, envs)
    db.execute("UPDATE readings SET weight=73 WHERE id=?", (r["id"],))
    db.commit()
    again, _ = sync.collect(db, nxt)
    assert again[0]["version"] > envs[0]["version"]


def test_delete_is_sent_only_if_entity_was_sent_before():
    never = reading(w=60)
    db.execute("DELETE FROM readings WHERE id=?", (never["id"],))
    sent = reading(w=61)
    envs, nxt = sync.collect(db, 0)
    assert [e["id"] for e in envs] == [sent["sync_id"]]  # the never-sent one produced no noise
    sync.mark_sent(db, envs)
    db.execute("DELETE FROM readings WHERE id=?", (sent["id"],))
    db.commit()
    dele, _ = sync.collect(db, nxt)
    assert dele[0]["op"] == "delete" and dele[0]["id"] == sent["sync_id"]
    direct, _ = sync.collect(db, nxt, only_if_live=False)
    assert len(direct) == 1


def test_meals_leave_only_when_confirmed_and_are_withdrawn_when_discarded():
    mid = meal(status="pending")
    assert sync.collect(db, 0)[0] == []
    food.set_status(db, mid, "confirmed")
    envs, nxt = sync.collect(db, 0)
    assert len(envs) == 1 and envs[0]["type"] == "meal" and envs[0]["data"]["kcal"] == 500
    assert envs[0]["data"]["items"][0]["name"] == "rice"
    sync.mark_sent(db, envs)
    food.set_status(db, mid, "discarded")
    out, _ = sync.collect(db, nxt)
    assert out[0]["op"] == "delete"


def test_inbound_weight_creates_reading_without_echo():
    out = sync.apply_batch(db, [env("weight", "hk-1", 10, ts=int(time.time()) - 60, weight_kg=81.2, fat_pct=22.5)])
    assert out["applied"] == 1
    r = db.execute("SELECT * FROM readings WHERE source='applehealth'").fetchone()
    assert r["weight"] == 81.2 and r["sync_id"] == "hk-1" and r["fat_pct_m"] == 22.5 and r["synced"] == 1
    assert db.execute("SELECT COUNT(*) FROM sync_outbox").fetchone()[0] == 0  # applying flag suppressed the trigger
    assert sync.collect(db, 0)[0] == []
    assert db.execute("SELECT v FROM sync_flags WHERE k='applying'").fetchone()[0] == 0


def test_inbound_duplicate_of_scale_reading_is_merged_not_inserted():
    now = int(time.time())
    scale = reading(w=70.0, ts=now)
    out = sync.apply_batch(db, [env("weight", "hk-2", 5, ts=now + 40, weight_kg=70.05, fat_pct=18.0, lean_kg=57.0)])
    assert out["merged"] == 1
    assert db.execute("SELECT COUNT(*) FROM readings").fetchone()[0] == 1
    r = db.execute("SELECT * FROM readings WHERE id=?", (scale["id"],)).fetchone()
    assert r["fat_pct_m"] == 18.0 and r["lean_kg_m"] == 57.0 and r["source"] == "scale"
    # deleting the Health sample only drops the link; the scale reading stays
    sync.apply_batch(db, [env("weight", "hk-2", 6, op="delete")])
    assert db.execute("SELECT COUNT(*) FROM readings").fetchone()[0] == 1
    assert db.execute("SELECT COUNT(*) FROM sync_links").fetchone()[0] == 0


def test_not_a_duplicate_when_far_apart():
    now = int(time.time())
    reading(w=70.0, ts=now)
    sync.apply_batch(db, [env("weight", "hk-3", 1, ts=now + 600, weight_kg=70.0)])
    sync.apply_batch(db, [env("weight", "hk-4", 1, ts=now + 30, weight_kg=71.0)])
    assert db.execute("SELECT COUNT(*) FROM readings").fetchone()[0] == 3


def test_last_writer_wins_and_tombstone_blocks_resurrection():
    ts = int(time.time()) - 5
    sync.apply_batch(db, [env("weight", "hk-5", 10, ts=ts, weight_kg=80)])
    assert sync.apply_batch(db, [env("weight", "hk-5", 8, ts=ts, weight_kg=99)])["stale"] == 1
    assert db.execute("SELECT weight FROM readings WHERE sync_id='hk-5'").fetchone()[0] == 80
    sync.apply_batch(db, [env("weight", "hk-5", 12, ts=ts, weight_kg=81)])
    assert db.execute("SELECT weight FROM readings WHERE sync_id='hk-5'").fetchone()[0] == 81
    sync.apply_batch(db, [env("weight", "hk-5", 15, op="delete")])
    assert db.execute("SELECT COUNT(*) FROM readings WHERE sync_id='hk-5'").fetchone() [0] == 0
    assert sync.apply_batch(db, [env("weight", "hk-5", 14, ts=ts, weight_kg=81)])["stale"] == 1
    assert db.execute("SELECT COUNT(*) FROM readings WHERE sync_id='hk-5'").fetchone()[0] == 0


def test_activity_nutrition_and_workouts():
    ts = int(time.time()) - 3600
    out = sync.apply_batch(db, [
        env("activity_day", "day:2026-11-13", 1, day="2026-11-13", active_kcal=640, basal_kcal=1700, steps=9100),
        env("nutrition_day", "day:2026-11-13", 1, day="2026-11-13", kcal=1800, protein_g=120, carbs_g=200, fat_g=60),
        env("workout", "w-1", 1, start_ts=ts, end_ts=ts + 1800, type="running", kcal=300, distance_m=5000),
    ])
    assert out["applied"] == 3
    assert dict(db.execute("SELECT * FROM activity_days").fetchone())["steps"] == 9100
    assert db.execute("SELECT kcal FROM nutrition_days").fetchone()[0] == 1800
    assert db.execute("SELECT type FROM workouts").fetchone()[0] == "running"
    sync.apply_batch(db, [env("activity_day", "day:2026-11-13", 2, day="2026-11-13", active_kcal=700, steps=9500)])
    assert db.execute("SELECT active_kcal FROM activity_days").fetchone()[0] == 700
    sync.apply_batch(db, [env("activity_day", "day:2026-11-13", 3, op="delete")])
    assert db.execute("SELECT COUNT(*) FROM activity_days").fetchone()[0] == 0


@pytest.mark.parametrize("bad", [
    env("weight", "x", 1, ts=int(time.time()), weight_kg=5),                    # implausible weight
    env("weight", "x", 1, ts=int(time.time()), weight_kg=True),                 # bool is not a number
    env("activity_day", "d", 1, day="yesterday", active_kcal=1),                # malformed day
    env("activity_day", "d", 1, day="2026-11-13", steps=-4),                    # negative
    env("workout", "w", 1, start_ts=5, end_ts=6),                               # before 2000
    env("meal", "m", 1, kcal=1),                                                # meals are outbound-only
    {"v": 2, "type": "weight", "op": "upsert", "id": "x", "version": 1, "data": {}},
    {"v": 1, "type": "weight", "op": "nuke", "id": "x", "version": 1},
    {"v": 1, "type": "weight", "op": "upsert", "id": "", "version": 1, "data": {}},
    "not a dict",
])
def test_invalid_envelopes_are_rejected_and_change_nothing(bad):
    assert sync.apply_batch(db, [bad])["invalid"] == 1
    assert db.execute("SELECT COUNT(*) FROM readings").fetchone()[0] == 0
    assert db.execute("SELECT v FROM sync_flags WHERE k='applying'").fetchone()[0] == 0


def test_sync_api_auth_changes_push_status():
    token = appmod.token()
    r = reading(w=75)

    async def go():
        async with TestClient(TestServer(appmod.make_app(False, True))) as c:
            h = {"Authorization": f"Bearer {token}"}
            unauth = (await c.get("/api/sync/v1/changes")).status
            wrong = (await c.get("/api/sync/v1/changes", headers={"Authorization": "Bearer nope"})).status
            ch = await (await c.get("/api/sync/v1/changes?since=0", headers=h)).json()
            pushed = await (await c.post("/api/sync/v1/push", headers=h, json={"items": [
                env("activity_day", "day:2026-11-12", 1, day="2026-11-12", steps=1234)]})).json()
            bad = (await c.post("/api/sync/v1/push", headers=h, json={"items": "x"})).status
            st = await (await c.get("/api/sync/v1/status", headers=h)).json()
            cfg = await (await c.get(f"/api/sync/v1/config?token={token}")).json()
            return unauth, wrong, ch, pushed, bad, st, cfg
    unauth, wrong, ch, pushed, bad, st, cfg = asyncio.run(go())
    assert (unauth, wrong, bad) == (401, 401, 400)
    assert ch["items"][0]["id"] == r["sync_id"] and ch["has_more"] is False
    assert pushed["applied"] == 1 and st["activity_days"] == 1 and st["relay"]["configured"] in (True, False)
    assert cfg["envelope_version"] == 1


def test_startup_banner_never_contains_the_health_token():
    tok = appmod.token()
    assert tok not in appmod.startup_banner(8777)


def test_health_feed_still_authenticates_with_the_token():
    tok = appmod.token()

    async def go():
        async with TestClient(TestServer(appmod.make_app(False, True))) as c:
            return ((await c.get("/api/health/pending")).status,
                    (await c.get("/api/health/pending?token=wrong")).status,
                    (await c.get(f"/api/health/pending?token={tok}")).status)
    assert asyncio.run(go()) == (401, 401, 200)
