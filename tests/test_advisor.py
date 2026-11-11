import asyncio
import json
import time
from datetime import datetime

import pytest
from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer

from atomhealth import advisor, app as appmod, bot as botmod, config, llm
from atomhealth.llm import LLMError

DAY = 86400
NOW = time.time()
PLAN = {"kcal": 1900, "maintenance": 2300, "adjust": -400, "bmr": 1700, "goal": "lose", "sex": "male",
        "macros": [{"key": "protein", "g": 140}, {"key": "carbs", "g": 200}, {"key": "fat", "g": 60}],
        "limits": {"fiber_g": 27}, "target_weight": 75}


@pytest.fixture(autouse=True)
def clean():
    for t in ("meal_items", "meal_photos", "meals", "readings", "advice"):
        appmod.db.execute(f"DELETE FROM {t}")
    appmod.db.execute("DELETE FROM kv WHERE k IN ('telegram','ai','tg_last_summary')")
    appmod.db.commit()
    config.set_llm_overrides({})
    yield
    config.set_llm_overrides({})


def add_meal(days_ago, kcal, protein=0, name="rice", status="confirmed", hour=12):
    d = datetime.fromtimestamp(NOW - days_ago * DAY).replace(hour=hour, minute=0, second=0)
    cur = appmod.db.execute("INSERT INTO meals(ts, meal_type, kcal, protein_g, carbs_g, fat_g, fiber_g, status, raw_json) "
                            "VALUES(?,?,?,?,?,?,?,?,?)", (int(d.timestamp()), "lunch", kcal, protein, 0, 0, 0, status, "{}"))
    appmod.db.execute("INSERT INTO meal_items(meal_id, name, grams, kcal) VALUES(?,?,?,?)", (cur.lastrowid, name, 100, kcal))
    appmod.db.commit()


def add_weights(start, per_week, days=14):
    for i in range(days + 1):
        ts = int(NOW - (days - i) * DAY)
        appmod.db.execute("INSERT INTO readings(ts, weight) VALUES(?,?)", (ts, start + per_week * i / 7))
    appmod.db.commit()


def test_daily_series_counts_only_confirmed_meals_per_day():
    add_meal(0, 500, protein=30)
    add_meal(0, 300, status="pending")
    add_meal(1, 900)
    s = advisor.daily_series(appmod.db, 3, NOW)
    assert [d["kcal"] for d in s] == [0, 900, 500] and s[-1]["protein_g"] == 30 and s[-1]["meals"] == 1


def test_weight_trend_slope_and_thin_data():
    add_weights(80, -0.5)
    t = advisor.weight_trend(appmod.db, NOW)
    assert t["kg_per_week"] == pytest.approx(-0.5, abs=0.02) and t["readings"] >= 14
    appmod.db.execute("DELETE FROM readings")
    add_weights(80, -0.5, days=4)                       # span too short
    assert advisor.weight_trend(appmod.db, NOW) is None
    appmod.db.execute("DELETE FROM readings")
    appmod.db.execute("INSERT INTO readings(ts, weight) VALUES(?,80)", (int(NOW),))
    assert advisor.weight_trend(appmod.db, NOW) is None


def _series(kcal, complete=7):
    return [{"date": str(i), "kcal": kcal if i < complete else 0, "protein_g": 0, "meals": 1} for i in range(14)] + [
        {"date": "today", "kcal": 0, "protein_g": 0, "meals": 0}]


def test_real_maintenance_and_suggested_target_up():
    # ate 2000/day while losing 0.5 kg/week -> real maintenance 2000 + 550 = 2550; planned deficit -400 -> 2150
    real = advisor.real_maintenance(_series(2000), {"kg_per_week": -0.5}, PLAN)
    assert real["kcal"] == 2550 and real["days_logged"] == 7
    g = advisor.suggest_target(PLAN, real)
    assert g["kcal"] == 2150 and g["change"] == 250 and g["real_maintenance_kcal"] == 2550


def test_suggestion_never_goes_below_safety_floor():
    plan = {**PLAN, "kcal": 1700, "adjust": -700, "bmr": 1700}      # floor = max(1500, 0.9*1700) = 1530
    g = advisor.suggest_target(plan, {"kcal": 1800})
    assert g["kcal"] == 1530 and g["change"] == -170
    female = {**plan, "sex": "female", "bmr": 1200, "kcal": 1500}
    assert advisor.safety_floor(female) == 1200


def test_noise_and_thin_logging_give_no_estimate():
    assert advisor.real_maintenance(_series(2000, complete=3), {"kg_per_week": -0.5}, PLAN) is None
    assert advisor.real_maintenance(_series(2000), None, PLAN) is None
    odd = advisor.real_maintenance(_series(900), {"kg_per_week": 0.0}, PLAN)    # 900 < BMR: partial logging
    assert odd["kcal"] is None and advisor.suggest_target(PLAN, odd) is None
    assert advisor.suggest_target(PLAN, {"kcal": 2350}) is None   # 2350 - 400 = 1950 is only +50 vs 1900: ignored


def test_snapshot_and_headlines():
    for d in range(1, 8):
        add_meal(d, 2000, protein=100, name="pasta" if d % 2 else "salad")
    add_meal(0, 600, protein=40, name="omelette")
    add_weights(80, -0.5)
    s = advisor.snapshot(appmod.db, {"sex": "male", "age": 35}, {k: v for k, v in PLAN.items() if k != "sex"}, 79.0, NOW)
    assert s["today"]["kcal"] == 600 and s["days_logged"] == 7 + 1 - 1 or s["days_logged"] >= 7
    assert s["suggested_target"]["kcal"] == 2150 and s["weight_trend"]["kg_per_week"] < 0
    assert {f["name"] for f in s["recent_foods"]} >= {"pasta", "salad"}
    day = advisor.headline("day", s)
    assert "Today: 600 / 1,900 kcal · 1,300 left" in day and "Suggested daily target: 2,150 kcal (+250" in day
    week = advisor.headline("week", s)
    assert "Last 7 days: average" in week and "Weight trend: -0.50 kg/week" in week and "target 1,900" in week


def test_snapshot_with_meal_adds_meal_headline():
    meal = {"meal_type": "lunch", "totals": {"kcal": 760}, "items": [{"name": "pizza", "grams": 300, "kcal": 760}]}
    s = advisor.snapshot(appmod.db, {"sex": "male"}, PLAN, 80, NOW, meal=meal)
    assert s["this_meal"]["items"][0]["name"] == "pizza"
    assert "This meal: 760 kcal (40% of your daily target)." in advisor.headline("meal", s)


def _llm_server(handler):
    app = web.Application()
    app.router.add_post("/v1/chat/completions", handler)
    return TestServer(app)


def test_report_uses_llm_with_snapshot_and_strips_markdown():
    seen = {}

    async def handler(request):
        seen["body"] = await request.json()
        return web.json_response({"choices": [{"message": {"content": "**Nice work** - add _more_ protein at dinner tonight."}}]})

    async def go():
        async with _llm_server(handler) as srv:
            c = llm.LLM(base_url=str(srv.make_url("/v1")), model="m", api_key="k", timeout=5)
            snap = advisor.snapshot(appmod.db, {"sex": "male"}, PLAN, 80, NOW)
            return await advisor.report("week", snap, llm=c)
    r = asyncio.run(go())
    assert r["used_llm"] and r["text"] == "Nice work - add more protein at dinner tonight."
    user = seen["body"]["messages"][1]["content"]
    assert "Maximum 170 words" in user and '"daily_target_kcal": 1900' in user
    assert "Use ONLY numbers" in seen["body"]["messages"][0]["content"]


def test_report_falls_back_when_model_down_but_ask_raises(monkeypatch):
    async def nosleep(_):
        pass
    monkeypatch.setattr(llm.asyncio, "sleep", nosleep)

    async def down(request):
        return web.Response(status=503)

    async def go():
        async with _llm_server(down) as srv:
            c = llm.LLM(base_url=str(srv.make_url("/v1")), model="m", api_key="k", timeout=5)
            snap = advisor.snapshot(appmod.db, {"sex": "male"}, PLAN, 80, NOW)
            day = await advisor.report("day", snap, llm=c)
            try:
                await advisor.report("ask", snap, question="what now?", llm=c)
                asked = None
            except LLMError as e:
                asked = e
            return day, asked
    day, asked = asyncio.run(go())
    assert day["used_llm"] is False and "room for about 1,900 kcal" in day["text"] and "Today: 0 / 1,900 kcal" in day["headline"]
    assert "Protein is behind" in day["text"] and isinstance(asked, LLMError)


# ---------- bot integration ----------
SNAP = advisor.snapshot.__wrapped__ if hasattr(advisor.snapshot, "__wrapped__") else None


def _bot(**cfg_over):
    from tests.test_bot import make_bot
    bot, cfg = make_bot(**cfg_over)
    bot.context = lambda meal=None: {"today": {"kcal": 600, "protein_g": 40}, "daily_target_kcal": 1900,
                                     "this_meal": meal, "days_logged": 3, "avg_kcal_logged_days": 1800,
                                     "weight_trend": None, "suggested_target": None}
    return bot, cfg


@pytest.fixture
def fake_report(monkeypatch):
    calls = []

    async def fake(kind, snap, question=None, llm=None):
        calls.append((kind, question))
        if kind == "ask" and question == "boom":
            raise LLMError("down")
        return {"headline": f"HEAD {kind}", "text": f"TEXT <{kind}>", "used_llm": True}
    monkeypatch.setattr(advisor, "report", fake)
    return calls


def _upd(text, uid=42):
    return {"update_id": 1, "message": {"chat": {"id": uid, "type": "private"}, "from": {"id": uid}, "text": text}}


def test_bot_advice_week_ask_commands(fake_report):
    async def go():
        bot, _ = _bot()
        for t in ("/advice", "/week", "/ask what should I eat?", "/ask", "/ask boom"):
            await bot.handle_update(_upd(t))
        return bot
    bot = asyncio.run(go())
    assert fake_report == [("day", None), ("week", None), ("ask", "what should I eat?"), ("ask", "boom")]
    edits = [e["text"] for e in bot.api.of("editMessageText")]
    assert "Today's advice" in edits[0] and "HEAD day" in edits[0] and "TEXT &lt;day&gt;" in edits[0]
    assert "Weekly review" in edits[1] and "HEAD ask" in edits[2]
    assert "isn't reachable" in edits[3]
    assert any("Ask me something" in m["text"] for m in bot.api.of("sendMessage"))


def test_bot_meal_message_has_advice_button_and_tip_callback(fake_report):
    from tests.test_bot import photo_msg, GOOD
    from atomhealth import food

    async def fake_analyze(images, caption, llm=None):
        return food.validate(GOOD)

    async def go():
        bot, _ = _bot()
        orig = food.analyze_meal
        food.analyze_meal = fake_analyze
        try:
            await bot.handle_update(photo_msg())
        finally:
            food.analyze_meal = orig
        kb = bot.api.of("editMessageText")[-1]["reply_markup"]["inline_keyboard"]
        mid = appmod.db.execute("SELECT id FROM meals").fetchone()[0]
        cq = {"id": "c", "from": {"id": 42}, "data": f"tip:{mid}", "message": {"chat": {"id": 42}, "message_id": 101}}
        await bot.handle_update({"update_id": 2, "callback_query": cq})
        await asyncio.gather(*bot._tasks)
        return bot, kb
    bot, kb = asyncio.run(go())
    assert [b["text"] for row in kb for b in row] == ["✅ Save", "🗑 Discard", "💡 Advice"]
    assert fake_report == [("meal", None)]
    assert "Advice for this meal" in bot.api.of("editMessageText")[-1]["text"]


def test_scheduled_summary_sends_once_per_day_and_weekly_on_sunday(fake_report):
    async def go():
        bot, _ = _bot(summary_time="00:00")
        add_meal(0, 700)
        bot._scheduled()
        bot._scheduled()                                   # same day: nothing more
        await asyncio.gather(*bot._tasks)
        appmod.db.execute("DELETE FROM kv WHERE k='tg_last_summary'")
        appmod.db.commit()
        bot._scheduled(now=datetime(2026, 11, 15, 22, 0))  # a Sunday
        await asyncio.gather(*bot._tasks)
        return bot
    bot = asyncio.run(go())
    assert fake_report == [("day", None), ("week", None)]
    titles = [e["text"] for e in bot.api.of("editMessageText")]
    assert "Daily summary" in titles[0] and "Weekly review" in titles[1]
    assert {m["chat_id"] for m in bot.api.of("sendMessage")} == {42}


def test_scheduled_summary_respects_time_switch_and_empty_days(fake_report):
    async def go():
        bot, _ = _bot(summary_time="23:59")
        add_meal(0, 700)
        bot._scheduled(now=datetime(2026, 11, 11, 20, 0))       # too early
        off, _ = _bot(daily_summary=False, summary_time="00:00")
        off._scheduled()
        quiet, _ = _bot(summary_time="00:00")                   # nothing logged today -> silent, but marked
        appmod.db.execute("DELETE FROM meals")
        appmod.db.commit()
        quiet._scheduled()
        await asyncio.gather(*bot._tasks, *off._tasks, *quiet._tasks)
        return quiet
    quiet = asyncio.run(go())
    assert fake_report == [] and quiet.kv_get("tg_last_summary")


# ---------- API ----------
def _client(fn):
    async def go():
        async with TestClient(TestServer(appmod.make_app(False, True))) as c:
            return await fn(c)
    return asyncio.run(go())


def test_advice_endpoint_saves_and_state_feed(monkeypatch, fake_report):
    async def fn(c):
        none = await c.post("/api/advice", json={"kind": "day"})        # no weight reading -> no plan
        appmod.db.execute("INSERT INTO readings(ts, weight) VALUES(?, 82)", (int(NOW),))
        appmod.db.commit()
        ok = await (await c.post("/api/advice", json={"kind": "day"})).json()
        wk = await (await c.post("/api/advice", json={"kind": "week"})).json()
        ask = await (await c.post("/api/advice", json={"kind": "ask", "q": "dinner?"})).json()
        bad = await c.post("/api/advice", json={"kind": "meal"})
        noq = await c.post("/api/advice", json={"kind": "ask"})
        state = await (await c.get("/api/state")).json()
        return none.status, ok, wk, ask, bad.status, noq.status, state["advice"]
    none, ok, wk, ask, bad, noq, feed = _client(fn)
    assert none == 422 and bad == 400 and noq == 400
    assert ok["headline"] == "HEAD day" and wk["text"] == "TEXT <week>"
    assert [i["kind"] for i in feed["today"]] == ["ask", "week", "day"] and feed["today"][0]["question"] == "dinner?"
    assert feed["week"]["kind"] == "week" and all(i["source"] == "dashboard" for i in feed["today"])


def test_feed_keeps_latest_weekly_review_and_only_todays_messages():
    r = {"headline": "H", "text": "T", "used_llm": True}
    advisor.save_advice(appmod.db, "day", r, ts=NOW - 2 * DAY)
    advisor.save_advice(appmod.db, "week", r, ts=NOW - 3 * DAY)
    advisor.save_advice(appmod.db, "week", r, ts=NOW - 20 * DAY)
    mine = advisor.save_advice(appmod.db, "meal", r, meal_id=5, source="telegram", ts=NOW)
    f = advisor.feed(appmod.db, NOW)
    assert [i["id"] for i in f["today"]] == [mine] and f["week"]["kind"] == "week"
    assert advisor.feed(appmod.db, NOW + 30 * DAY) == {"today": [], "week": None}


def test_bot_coach_saves_advice_and_notifies(fake_report):
    async def go():
        bot, _ = _bot()
        pinged = []
        bot.notify = lambda: pinged.append(1)
        await bot.handle_update(_upd("/advice"))
        await bot.handle_update(_upd("/ask what now?"))
        return pinged
    pinged = asyncio.run(go())
    rows = appmod.db.execute("SELECT kind, question, source, headline FROM advice ORDER BY id").fetchall()
    assert [(r[0], r[1], r[2]) for r in rows] == [("day", None, "telegram"), ("ask", "what now?", "telegram")]
    assert rows[0][3] == "HEAD day" and len(pinged) == 2


def test_summary_settings_roundtrip(monkeypatch):
    async def fake_apply(self):
        pass
    monkeypatch.setattr(botmod.TelegramBot, "apply", fake_apply)

    async def fn(c):
        bad = await c.post("/api/settings/telegram", json={"summary_time": "25:00"})
        ok = await c.post("/api/settings/telegram", json={"summary_time": "20:30", "daily_summary": False})
        return bad.status, (await ok.json())["telegram"]
    bad, t = _client(fn)
    assert bad == 400 and t["summary_time"] == "20:30" and t["daily_summary"] is False
