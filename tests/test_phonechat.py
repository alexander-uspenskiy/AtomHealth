import asyncio
import base64
import time

import pytest
from aiohttp.test_utils import TestServer

from atomhealth import app as appmod, bot as botmod, food, intent, phonechat, relay
from atomhealth.llm import LLMError

from .test_bot import GOOD, JPEG
from .test_relay import KEY, FakeRelay, MemSecrets

db = appmod.db


@pytest.fixture(autouse=True)
def clean(monkeypatch):
    for t in ("meal_items", "meal_photos", "meals"):
        db.execute(f"DELETE FROM {t}")
    db.execute("DELETE FROM kv WHERE k LIKE 'pc_%' OR k LIKE 'relay%'")
    db.commit()

    async def down(*a, **k):
        raise LLMError("offline")
    monkeypatch.setattr(intent, "classify", down)


def make_chat():
    return phonechat.PhoneChat(lambda k, d=None: appmod.kv_get("pc_" + k, d), lambda k, v: appmod.kv_set("pc_" + k, v))


def e(sid, **data):
    return {"v": 1, "type": "chat_in", "op": "upsert", "id": sid, "version": 1, "updated_at": 0, "data": data}


def chunks(pid, raw, size):
    parts = [raw[i:i + size] for i in range(0, len(raw), size)]
    return [e(f"{pid}-{i}", kind="photo", photo_id=pid, idx=i, n=len(parts), b64=base64.b64encode(p).decode())
            for i, p in enumerate(parts)]


def test_text_and_command_become_telegram_updates():
    c = make_chat()
    c.ingest(e("a1", kind="text", text="  /today "))
    c.ingest(e("a1", kind="text", text="/today"))               # replay of the same record id is ignored
    [u] = c.updates
    assert u["message"]["text"] == "/today" and u["message"]["chat"]["type"] == "private"
    assert u["message"]["from"]["id"] == phonechat.PHONE_UID


def test_photo_chunks_reassemble_and_album_shares_a_group():
    c = make_chat()
    raw = JPEG * 40
    for x in chunks("p1", raw, 7000) + chunks("p2", JPEG, 7000):
        c.ingest(x)
    assert not c.updates                                          # chunks alone start nothing
    c.ingest(e("m1", kind="message", text="homemade", photos=["p1", "p2"]))
    a, b = c.updates
    assert a["message"]["caption"] == "homemade" and "caption" not in b["message"]
    assert a["message"]["media_group_id"] == b["message"]["media_group_id"]
    assert c.take_file(a["message"]["photo"][-1]["file_id"]) == raw
    assert c.take_file(b["message"]["photo"][-1]["file_id"]) == JPEG
    with pytest.raises(KeyError):
        c.take_file("pc:p1")                                      # one download each


def test_missing_chunk_is_reported_not_analysed():
    c = make_chat()
    c.ingest(chunks("p1", JPEG * 5, 3000)[0])
    c.ingest(e("m1", kind="message", text="", photos=["p1"]))
    assert not c.updates
    assert "did not arrive" in c.drain()[0]["data"]["text"]


def test_bad_input_is_counted_and_never_raises():
    c = make_chat()
    for bad in (e("b1", kind="photo", photo_id="x", idx=5, n=2, b64="AAAA"),
                e("b2", kind="photo", photo_id="../x", idx=0, n=1, b64="AAAA"),
                e("b3", kind="photo", photo_id="x", idx=0, n=1, b64="!!!"),
                e("b4", kind="photo", photo_id="x", idx=0, n=1,
                  b64=base64.b64encode(b"x" * (phonechat.CHUNK_MAX + 1)).decode()),
                e("b5", kind="callback", data="save:1", msg_id="1"),
                e("b6", kind="message", photos=[]),
                e("b7", kind="nope"), {"id": "b8", "op": "upsert", "data": {}}, {"id": "b9", "op": "delete"}):
        c.ingest(bad)
    assert c.problems == 8 and not c.updates and not c._partial


def test_outgoing_edit_keeps_id_and_creation_time_and_raises_version():
    c = make_chat()
    mid = c.send("<b>hi</b>", {"inline_keyboard": [[{"text": "Save", "callback_data": "save:1"}]]})
    c.edit(mid, "done", {"inline_keyboard": []})
    first, second = c.drain()
    assert first["id"] == second["id"] == f"m{mid}" and second["version"] > first["version"]
    assert first["data"]["buttons"] == [[{"text": "Save", "data": "save:1"}]] and second["data"]["buttons"] == []
    assert second["data"]["ts"] == first["data"]["ts"] and second["data"]["edited"]
    assert c.send("next") == mid + 1                              # ids survive restarts via kv


def make_phone_bot(chat, monkeypatch, analyzed):
    cfg = {"enabled": True, "token": "phone-chat-local", "allowed_ids": {phonechat.PHONE_UID},
           "auto_save": False, "session_minutes": 10, "daily_summary": False, "summary_time": "21:00"}
    return botmod.TelegramBot(db, cfg=lambda: cfg, target_kcal=lambda: 2000, latest_weight=lambda: (80.0, 1_700_000_000),
                              kv_get=lambda k, d=None: appmod.kv_get("pc_" + k, d), kv_set=lambda k, v: appmod.kv_set("pc_" + k, v),
                              api_factory=lambda t, b: phonechat.PhoneApi(chat), source="phone")


@pytest.fixture
def analyzed(monkeypatch):
    calls = []

    async def fake(images, caption, llm=None):
        calls.append({"n": len(images or []), "bytes": [len(i) for i in images or []], "caption": caption})
        return food.validate(GOOD)

    monkeypatch.setattr(food, "analyze_meal", fake)
    return calls


async def settle(chat, bot, want=1, tries=100):
    for _ in range(tries):
        if len(chat.out) >= want and not bot._tasks:
            return
        await asyncio.sleep(0.02)


def test_phone_bot_answers_commands_and_meal_photos_with_buttons(analyzed, monkeypatch):
    monkeypatch.setattr(botmod, "ALBUM_WAIT", 0.05)

    async def go():
        chat = make_chat()
        bot = make_phone_bot(chat, monkeypatch, analyzed)
        await bot.apply()
        chat.ingest(e("t1", kind="text", text="/weight"))
        await settle(chat, bot)
        weight = chat.drain()
        for x in chunks("p1", JPEG * 30, 20000):
            chat.ingest(x)
        chat.ingest(e("m1", kind="message", text="rice", photos=["p1"]))
        await settle(chat, bot, want=2)
        meal = chat.drain()
        mid = db.execute("SELECT id FROM meals").fetchone()[0]
        chat.ingest(e("c1", kind="callback", data=f"save:{mid}", msg_id=meal[-1]["data"]["mid"]))
        await settle(chat, bot, want=1)
        saved = chat.drain()
        await bot.stop()
        return weight, meal, saved

    weight, meal, saved = asyncio.run(go())
    assert "80.0 kg" in weight[0]["data"]["text"] and weight[0]["type"] == "chat_out"
    assert analyzed == [{"n": 1, "bytes": [len(JPEG) * 30], "caption": "rice"}]
    final = meal[-1]["data"]
    assert "rice" in final["text"] and [b["data"].split(":")[0] for b in final["buttons"][0]] == ["save", "del"]
    assert db.execute("SELECT source FROM meals").fetchone()[0] == "phone"
    assert any("Saved" in s["data"].get("text", "") for s in saved)
    assert db.execute("SELECT status FROM meals").fetchone()[0] == "confirmed"


def test_agent_carries_chat_both_ways_through_the_relay(analyzed, monkeypatch):
    fake = FakeRelay()

    async def go():
        async with TestServer(fake.app()) as srv:
            appmod.kv_set("relay", {"url": str(srv.make_url("")).rstrip("/"), "device_id": "mac1"})
            chat = make_chat()
            agent = relay.RelayAgent(db, appmod.kv_get, appmod.kv_set, chat=chat,
                                     secret_store=MemSecrets(token="mac1.secret", key=relay.b64e(KEY)))
            bot = make_phone_bot(chat, monkeypatch, analyzed)
            await bot.apply()
            rec = relay.encrypt(KEY, "phone1", "phone-rec-0001", e("t1", kind="text", text="/weight"))
            fake.records.append({**rec, "seq": 1, "device_id": "phone1"})
            await agent.cycle(chat_only=True)                    # pulls the question
            await settle(chat, bot)
            woke = agent._wake.is_set()
            await agent.cycle(chat_only=True)                    # pushes the answer
            await bot.stop()
            return [relay.decrypt(KEY, r["device_id"], r["record_id"], r["nonce"], r["ciphertext"])
                    for r in fake.records if r["device_id"] == "mac1"], woke, agent

    out, woke, agent = asyncio.run(go())
    assert woke and len(out) == 1 and out[0]["type"] == "chat_out" and "80.0 kg" in out[0]["data"]["text"]
    assert agent.state["bad"] == 0
    assert db.execute("SELECT COUNT(*) FROM sync_log WHERE status!='ok'").fetchone()[0] == 0


def test_failed_chat_push_is_requeued():
    fake = FakeRelay()
    fake.fail_push = True

    async def go():
        async with TestServer(fake.app()) as srv:
            appmod.kv_set("relay", {"url": str(srv.make_url("")).rstrip("/"), "device_id": "mac1"})
            chat = make_chat()
            agent = relay.RelayAgent(db, appmod.kv_get, appmod.kv_set, chat=chat,
                                     secret_store=MemSecrets(token="mac1.secret", key=relay.b64e(KEY)))
            chat.send("hello")
            with pytest.raises(relay.RelayError):
                await agent.cycle(chat_only=True)
            assert len(chat.out) == 1
            fake.fail_push = False
            await agent.cycle(chat_only=True)
            return chat, fake
    chat, fake = asyncio.run(go())
    assert not chat.out and len(fake.records) == 1


def test_ping_is_answered_at_once_with_presence_and_ai_state():
    c = make_chat()
    c.ingest(e("pg1", kind="ping"))
    c.ai_ok = False
    c.ingest(e("pg2", kind="ping"))
    c.ingest(e("pg2", kind="ping"))                              # replay: no second answer
    a, b = c.drain()
    assert a["id"] == b["id"] == "presence" and b["version"] > a["version"]
    assert a["data"]["ai"] is None and b["data"]["ai"] is False and abs(b["data"]["ts"] - time.time()) < 5
    assert not c.updates                                          # a ping never reaches the bot
