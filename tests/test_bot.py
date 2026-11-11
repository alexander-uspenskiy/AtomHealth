import asyncio
import io
import json
import time

import pytest
from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer
from PIL import Image

from atomhealth import app as appmod, bot as botmod, config, food
from atomhealth.llm import LLMError

b = io.BytesIO()
Image.new("RGB", (300, 200), (90, 160, 60)).save(b, "JPEG")
JPEG = b.getvalue()

GOOD = {"is_food": True, "meal_type": "lunch", "confidence": 0.7, "notes": "portion guessed",
        "items": [{"name": "rice", "grams": 200, "kcal": 260, "protein_g": 5, "carbs_g": 57, "fat_g": 0.5, "fiber_g": 1},
                  {"name": "chicken <b>", "grams": 120, "kcal": 198, "protein_g": 37, "carbs_g": 0, "fat_g": 4, "fiber_g": 0}]}


@pytest.fixture(autouse=True)
def clean():
    for t in ("meal_items", "meal_photos", "meals"):
        appmod.db.execute(f"DELETE FROM {t}")
    appmod.db.execute("DELETE FROM kv WHERE k IN ('telegram','ai','tg_offset')")
    appmod.db.commit()
    config.set_llm_overrides({})
    yield
    config.set_llm_overrides({})


class FakeApi:
    def __init__(self):
        self.calls, self.n = [], 100

    async def call(self, method, **p):
        self.calls.append((method, p))
        if method == "sendMessage":
            self.n += 1
            return {"message_id": self.n}
        return {}

    async def download(self, fid):
        return JPEG

    def of(self, method):
        return [p for m, p in self.calls if m == method]


def make_bot(**over):
    cfg = {"enabled": True, "token": "1:x", "allowed_ids": {42}, "auto_save": False, "session_minutes": 10, **over}
    kvs = {}
    bot = botmod.TelegramBot(appmod.db, cfg=lambda: cfg, target_kcal=lambda: 2000,
                             latest_weight=lambda: (80.0, 1_700_000_000),
                             kv_get=lambda k, d=None: kvs.get(k, d), kv_set=kvs.__setitem__)
    bot.api = FakeApi()
    return bot, cfg


@pytest.fixture
def analyzed(monkeypatch):
    calls = []

    async def fake(images, caption, llm=None):
        calls.append({"n": len(images or []), "caption": caption})
        return food.validate(GOOD)

    monkeypatch.setattr(food, "analyze_meal", fake)
    return calls


def photo_msg(uid=42, group=None, caption=None, fid="f1"):
    m = {"chat": {"id": uid, "type": "private"}, "from": {"id": uid}, "photo": [{"file_id": "small"}, {"file_id": fid}]}
    if group:
        m["media_group_id"] = group
    if caption:
        m["caption"] = caption
    return {"update_id": 1, "message": m}


def text_msg(text, uid=42):
    return {"update_id": 1, "message": {"chat": {"id": uid, "type": "private"}, "from": {"id": uid}, "text": text}}


def run(coro):
    return asyncio.run(coro)


def meal_count():
    return appmod.db.execute("SELECT COUNT(*) FROM meals").fetchone()[0]


def test_stranger_gets_their_id_once_and_nothing_else():
    async def go():
        bot, _ = make_bot()
        await bot.handle_update(text_msg("hi", uid=7))        # any first message gets the ID
        await bot.handle_update(text_msg("hello?", uid=7))    # but not again within 10 minutes
        await bot.handle_update(text_msg("/start", uid=7))    # /start always answers
        await bot.handle_update(photo_msg(uid=7))             # photos from strangers are never analysed
        return bot
    bot = run(go())
    sent = bot.api.of("sendMessage")
    assert len(sent) == 2 and all("<code>7</code>" in m["text"] for m in sent)
    assert bot.status()["contacts"][0]["id"] == 7 and "replied" not in bot.status()["contacts"][0]
    assert meal_count() == 0 and not bot.api.of("editMessageText")


def test_start_welcomes_with_daily_limit_and_what_is_left(analyzed):
    plan = {"kcal": 2100, "goal": "lose", "macros": [{"key": "protein", "g": 130}, {"key": "carbs", "g": 220}, {"key": "fat", "g": 70}]}

    async def go():
        bot, _ = make_bot()
        bot.plan = lambda: plan
        await bot.handle_update({"update_id": 1, "message": {"chat": {"id": 42, "type": "private"},
                                                           "from": {"id": 42, "first_name": "Al<ex>"}, "text": "/start"}})
        await bot.handle_update(photo_msg())
        meal = appmod.db.execute("SELECT id FROM meals").fetchone()[0]
        food.set_status(appmod.db, meal, "confirmed")
        await bot.handle_update(text_msg("/start"))
        bot.plan = lambda: {}
        await bot.handle_update(text_msg("/start"))
        return bot
    texts = [m["text"] for m in run(go()).api.of("sendMessage") if "Welcome" in m["text"]]
    assert "Welcome, Al&lt;ex&gt;!" in texts[0] and "<b>2,100 kcal</b> (goal: lose weight)" in texts[0]
    assert "Protein 130 g · Carbs 220 g · Fat 70 g" in texts[0] and "Today so far: 0 kcal → 2,100 left" in texts[0]
    assert "Today so far: 458 kcal → 1,642 left" in texts[1] and "/today" in texts[1]
    assert "don't have a daily calorie limit" in texts[2]


def test_group_chats_are_ignored():
    async def go():
        bot, _ = make_bot()
        u = photo_msg()
        u["message"]["chat"]["type"] = "group"
        await bot.handle_update(u)
        return bot
    assert run(go()).api.calls == []


def test_photo_creates_pending_meal_with_buttons_and_escaped_text(analyzed):
    async def go():
        bot, _ = make_bot()
        await bot.handle_update(photo_msg(caption="homemade"))
        return bot
    bot = run(go())
    assert analyzed == [{"n": 1, "caption": "homemade"}] and meal_count() == 1
    edit = bot.api.of("editMessageText")[-1]
    assert "458 kcal" in edit["text"] and "chicken &lt;b&gt;" in edit["text"] and "Today: 458 / 2,000 kcal" in edit["text"]
    mid = appmod.db.execute("SELECT id FROM meals").fetchone()[0]
    assert edit["reply_markup"]["inline_keyboard"][0][0]["callback_data"] == f"save:{mid}"
    assert appmod.db.execute("SELECT status FROM meals").fetchone()[0] == "pending"


def test_second_photo_in_session_extends_same_meal(analyzed):
    async def go():
        bot, _ = make_bot()
        await bot.handle_update(photo_msg())
        await bot.handle_update(photo_msg(fid="f2", caption="plus dessert"))
        return bot
    bot = run(go())
    assert [c["n"] for c in analyzed] == [1, 2] and meal_count() == 1
    assert food.meal_photo_count(appmod.db, appmod.db.execute("SELECT id FROM meals").fetchone()[0]) == 2
    assert any("Updated below" in e["text"] for e in bot.api.of("editMessageText"))


def test_expired_session_starts_new_meal(analyzed):
    async def go():
        bot, _ = make_bot()
        await bot.handle_update(photo_msg())
        bot.sessions[42]["last"] -= 11 * 60
        await bot.handle_update(photo_msg())
    run(go())
    assert meal_count() == 2


def test_album_is_analysed_once_with_all_photos(analyzed, monkeypatch):
    monkeypatch.setattr(botmod, "ALBUM_WAIT", 0.05)

    async def go():
        bot, _ = make_bot()
        for i in range(3):
            await bot.handle_update(photo_msg(group="g1", fid=f"p{i}", caption="dinner" if i == 0 else None))
        await asyncio.sleep(0.3)
        await asyncio.gather(*bot._tasks)
    run(go())
    assert analyzed == [{"n": 3, "caption": "dinner"}] and meal_count() == 1


def test_save_button_confirms_and_ends_session(analyzed):
    async def go():
        bot, _ = make_bot()
        await bot.handle_update(photo_msg())
        mid = appmod.db.execute("SELECT id FROM meals").fetchone()[0]
        cq = {"id": "c1", "from": {"id": 42}, "data": f"save:{mid}", "message": {"chat": {"id": 42}, "message_id": 101}}
        await bot.handle_update({"update_id": 3, "callback_query": cq})
        await bot.handle_update({"update_id": 4, "callback_query": {**cq, "id": "c2"}})  # double tap
        await bot.handle_update(photo_msg())  # new meal, not an extension
        return bot
    bot = run(go())
    assert [c["text"] for c in bot.api.of("answerCallbackQuery")] == ["Saved ✓", "Already confirmed"]
    assert any("✅ Saved" in e["text"] for e in bot.api.of("editMessageText"))
    assert meal_count() == 2
    assert appmod.db.execute("SELECT COUNT(*) FROM meals WHERE status='confirmed'").fetchone()[0] == 1


def test_callbacks_from_strangers_are_ignored(analyzed):
    async def go():
        bot, _ = make_bot()
        await bot.handle_update(photo_msg())
        await bot.handle_update({"update_id": 3, "callback_query": {"id": "x", "from": {"id": 99}, "data": "save:1",
                                                                    "message": {"chat": {"id": 99}, "message_id": 1}}})
    run(go())
    assert appmod.db.execute("SELECT status FROM meals").fetchone()[0] == "pending"


def test_sweep_auto_saves_only_when_enabled(analyzed):
    async def go(auto):
        bot, _ = make_bot(auto_save=auto)
        await bot.handle_update(photo_msg())
        bot.sessions[42]["last"] -= 11 * 60
        await bot.sweep()
        return bot
    run(go(False))
    assert appmod.db.execute("SELECT status FROM meals").fetchone()[0] == "pending"
    appmod.db.execute("DELETE FROM meals")
    bot = run(go(True))
    assert appmod.db.execute("SELECT status FROM meals").fetchone()[0] == "confirmed" and not bot.sessions


def test_text_description_and_non_food(monkeypatch):
    async def fake(images, caption, llm=None):
        return food.validate(GOOD) if "egg" in caption else food.validate({"is_food": False, "notes": "greeting"})
    monkeypatch.setattr(food, "analyze_meal", fake)

    async def go():
        bot, _ = make_bot()
        await bot.handle_update(text_msg("hello there"))
        n_after_hello = meal_count()
        await bot.handle_update(text_msg("2 eggs and toast"))
        return bot, n_after_hello
    bot, n = run(go())
    assert n == 0 and meal_count() == 1
    assert "couldn't find any food" in bot.api.of("editMessageText")[0]["text"]


def test_model_down_reports_and_stores_nothing(monkeypatch):
    async def boom(images, caption, llm=None):
        raise LLMError("down")
    monkeypatch.setattr(food, "analyze_meal", boom)

    async def go():
        bot, _ = make_bot()
        await bot.handle_update(photo_msg())
        return bot
    bot = run(go())
    assert "isn't reachable" in bot.api.of("editMessageText")[-1]["text"] and meal_count() == 0


def test_commands_today_undo_weight_help(analyzed):
    async def go():
        bot, _ = make_bot()
        await bot.handle_update(text_msg("/today"))
        await bot.handle_update(photo_msg())
        mid = appmod.db.execute("SELECT id FROM meals").fetchone()[0]
        food.set_status(appmod.db, mid, "confirmed")
        await bot.handle_update(text_msg("/today@my_bot"))
        await bot.handle_update(text_msg("/weight"))
        await bot.handle_update(text_msg("/undo"))
        await bot.handle_update(text_msg("/undo"))
        await bot.handle_update(text_msg("/help"))
        return bot
    texts = [m["text"] for m in run(go()).api.of("sendMessage") if m["text"] != "🔍 Analysing…"]
    assert "Nothing logged today" in texts[0]
    assert "458 kcal" in texts[1] and "1,542 left" in texts[1]
    assert "80.0 kg" in texts[2] and "Discarded" in texts[3] and "Nothing to undo" in texts[4] and "/today" in texts[5]
    assert appmod.db.execute("SELECT status FROM meals").fetchone()[0] == "discarded"


# ---------- transport: polling against a fake Telegram server ----------
def _fake_telegram(updates, token_ok=True):
    sent, state = [], {"served": False}

    async def handler(request):
        method = request.match_info["method"]
        if not token_ok:
            return web.json_response({"ok": False, "error_code": 401, "description": "Unauthorized"}, status=401)
        body = await request.json()
        if method == "getMe":
            return web.json_response({"ok": True, "result": {"username": "food_bot"}})
        if method == "getUpdates":
            await asyncio.sleep(0.05)
            if not state["served"]:
                state["served"] = True
                return web.json_response({"ok": True, "result": updates})
            return web.json_response({"ok": True, "result": []})
        if method == "sendMessage":
            sent.append(body)
            return web.json_response({"ok": True, "result": {"message_id": 5}})
        return web.json_response({"ok": True, "result": {}})

    app = web.Application()
    app.router.add_post("/bot{token}/{method}", handler)
    return app, sent


def _poll(updates, token_ok=True):
    async def go():
        fake, sent = _fake_telegram(updates, token_ok)
        async with TestServer(fake) as srv:
            kvs = {}
            bot = botmod.TelegramBot(appmod.db, cfg=lambda: {"enabled": True, "token": "123:SECRET", "allowed_ids": {42},
                                                             "auto_save": False, "session_minutes": 10},
                                     target_kcal=lambda: None, latest_weight=lambda: None,
                                     kv_get=lambda k, d=None: kvs.get(k, d), kv_set=kvs.__setitem__,
                                     api_base=str(srv.make_url("")).rstrip("/"))
            await bot.apply()
            for _ in range(60):
                await asyncio.sleep(0.05)
                if sent or bot.state == "error":
                    break
            snap = (bot.state, bot.username, bot.error, dict(kvs))
            await bot.stop()
            return snap, sent, bot.state
    return run(go())


def test_polling_connects_replies_and_persists_offset():
    (state, username, err, kvs), sent, after = _poll([text_msg("/start", uid=7) | {"update_id": 10}])
    assert state == "running" and username == "food_bot" and err is None
    assert len(sent) == 1 and "<code>7</code>" in sent[0]["text"] and kvs["tg_offset"] == 11
    assert after == "stopped"


def test_polling_reports_rejected_token():
    (state, _, err, _), _, _ = _poll([], token_ok=False)
    assert state == "error" and "token" in err.lower()


# ---------- Settings API ----------
@pytest.fixture
def no_real_bot(monkeypatch):
    applied = []

    async def fake_apply(self):
        applied.append(1)
    monkeypatch.setattr(botmod.TelegramBot, "apply", fake_apply)
    return applied


def _api(fn):
    async def go():
        async with TestClient(TestServer(appmod.make_app(False, True))) as c:
            return await fn(c)
    return run(go())


def test_settings_roundtrip_hides_token(no_real_bot):
    async def fn(c):
        bad = await c.post("/api/settings/telegram", json={"token": "nope"})
        ids = await c.post("/api/settings/telegram", json={"allowed_ids": "12, abc"})
        mins = await c.post("/api/settings/telegram", json={"session_minutes": 0})
        ok = await c.post("/api/settings/telegram", json={"token": "123456:" + "A" * 30, "allowed_ids": "42, 7 42",
                                                          "auto_save": True, "session_minutes": 15, "enabled": True})
        raw = await ok.text()
        got = (await (await c.get("/api/settings")).json())["telegram"]
        keep = await c.post("/api/settings/telegram", json={"auto_save": False})  # empty token keeps the old one
        cleared = await c.post("/api/settings/telegram", json={"clear_token": True})
        return bad.status, ids.status, mins.status, raw, got, (await keep.json())["telegram"], (await cleared.json())["telegram"]
    bad, ids, mins, raw, got, keep, cleared = _api(fn)
    assert (bad, ids, mins) == (400, 400, 400)
    assert "A" * 30 not in raw and got["has_token"] and got["token_hint"] == "A" * 4
    assert got["allowed_ids"] == [7, 42] and got["auto_save"] and got["session_minutes"] == 15
    assert keep["has_token"] and not keep["auto_save"] and not cleared["has_token"]
    assert len(no_real_bot) >= 2  # applied when the token changed and when it was removed


def test_ai_settings_and_connection_test():
    async def models(request):
        return web.json_response({"data": [{"id": "vl", "architecture": {"input_modalities": ["text", "image"]}},
                                           {"id": "txt", "architecture": {"input_modalities": ["text"]}}]})
    llm_app = web.Application()
    llm_app.router.add_get("/v1/models", models)

    async def go():
        async with TestServer(llm_app) as llm_srv:
            url = str(llm_srv.make_url("/v1"))
            async with TestClient(TestServer(appmod.make_app(False, True))) as c:
                bad = await c.post("/api/settings/ai", json={"base_url": "ftp://x"})
                await c.post("/api/settings/ai", json={"base_url": url, "model": "vl"})
                good = await (await c.post("/api/settings/ai/test")).json()
                await c.post("/api/settings/ai", json={"base_url": url, "model": "txt"})
                novision = await (await c.post("/api/settings/ai/test")).json()
                await c.post("/api/settings/ai", json={"base_url": url, "model": "missing"})
                missing = await (await c.post("/api/settings/ai/test")).json()
                active = config.llm_settings()["model"]
                reset = await (await c.post("/api/settings/ai", json={})).json()
                await c.post("/api/settings/ai", json={"base_url": "http://127.0.0.1:1/v1", "model": "x"})
                down = await (await c.post("/api/settings/ai/test")).json()
                return bad.status, good, novision, missing, active, reset, down
    bad, good, novision, missing, active, reset, down = run(go())
    assert bad == 400 and active == "missing"
    assert good["ok"] and good["vision"] is True and good["model_found"]
    assert novision["vision"] is False and not missing["model_found"] and not down["ok"]
    assert reset["ai"]["custom"] is False


def test_telegram_test_message_needs_running_bot():
    async def fn(c):
        return (await c.post("/api/settings/telegram/test")).status
    assert _api(fn) == 409
