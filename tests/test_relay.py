import asyncio
import json
import time

import pytest
from aiohttp import web
from aiohttp.test_utils import TestServer

from atomhealth import app as appmod, food, relay, sync

db = appmod.db
KEY = bytes(range(32))


class MemSecrets:
    def __init__(self, **kw):
        self.d = dict(kw)

    def get(self, name):
        return self.d.get(name)

    def set(self, name, value):
        self.d[name] = value


class FakeRelay:
    """In-process stand-in for the Cloudflare Worker: same wire contract, no persistence."""

    def __init__(self):
        self.records, self.acks, self.fail_push = [], [], False

    def device(self, req):
        h = req.headers.get("authorization", "")
        if not h.startswith("Bearer ") or "." not in h:
            raise web.HTTPUnauthorized(text=json.dumps({"error": "no"}))
        return h[7:].split(".")[0]

    async def push(self, req):
        dev = self.device(req)
        if self.fail_push:
            return web.json_response({"error": "boom"}, status=500)
        for r in (await req.json())["records"]:
            self.records.append({**r, "seq": len(self.records) + 1, "device_id": dev})
        return web.json_response({"seqs": []})

    async def pull(self, req):
        dev, since = self.device(req), int(req.query["since"])
        rows = [r for r in self.records if r["seq"] > since][:int(req.query.get("limit", 100))]
        out = [r for r in rows if r["device_id"] != dev]
        nxt = rows[-1]["seq"] if rows else since
        return web.json_response({"records": out, "next_seq": nxt, "has_more": nxt < len(self.records)})

    async def ack(self, req):
        self.device(req)
        self.acks.append((await req.json())["cursor"])
        return web.json_response({"ok": True})

    def app(self):
        a = web.Application()
        a.add_routes([web.post("/v1/push", self.push), web.get("/v1/pull", self.pull), web.post("/v1/ack", self.ack)])
        return a


@pytest.fixture(autouse=True)
def clean():
    for t in ("readings", "meals", "meal_items", "sync_outbox", "sync_versions", "sync_links", "sync_log",
              "activity_days", "nutrition_days", "workouts"):
        db.execute(f"DELETE FROM {t}")
    db.execute("DELETE FROM kv WHERE k LIKE 'relay%'")
    db.commit()
    yield


def env(type_, id_, version, **data):
    return {"v": 1, "type": type_, "op": "upsert", "id": id_, "version": version, "updated_at": 0, "data": data}


# ---------------------------------------------------------------------------- crypto
def test_crypto_roundtrip():
    e = env("weight", "a", 1, weight_kg=80)
    rec = relay.encrypt(KEY, "dev1", "rec-00001", e)
    assert "weight" not in json.dumps(rec)  # plaintext never appears on the wire
    assert relay.decrypt(KEY, "dev1", "rec-00001", rec["nonce"], rec["ciphertext"]) == e


def test_crypto_rejects_tampering_and_rebinding():
    rec = relay.encrypt(KEY, "dev1", "rec-00001", env("weight", "a", 1, weight_kg=80))
    n, c = rec["nonce"], rec["ciphertext"]
    for args in (("dev2", "rec-00001", n, c),                       # relay claims another sender
                 ("dev1", "rec-00002", n, c),                       # relay moved it to another record id
                 ("dev1", "rec-00001", n, c[:-4] + ("AAAA" if c[-4:] != "AAAA" else "BBBB"))):  # bit flip
        with pytest.raises(relay.CryptoError):
            relay.decrypt(KEY, *args)
    with pytest.raises(relay.CryptoError):
        relay.decrypt(bytes(32), "dev1", "rec-00001", n, c)         # wrong key
    assert len(relay.new_record_id()) >= 8


def test_nonces_are_unique():
    a = relay.encrypt(KEY, "d", "rec-00001", {"x": 1})["nonce"]
    b = relay.encrypt(KEY, "d", "rec-00001", {"x": 1})["nonce"]
    assert a != b


def test_relay_url_must_be_https_except_loopback():
    assert relay.check_url("https://x.workers.dev/") == "https://x.workers.dev"
    assert relay.check_url("http://localhost:8787") == "http://localhost:8787"
    for bad in ("http://example.com", "ftp://x", "https://"):
        with pytest.raises(relay.RelayError):
            relay.check_url(bad)


def test_secret_store_prefers_env(monkeypatch):
    monkeypatch.setenv("RELAY_TOKEN", "from-env")
    assert relay.SecretStore().get("token") == "from-env"


# ---------------------------------------------------------------------------- agent
def agent_for(srv, secrets=None):
    appmod.kv_set("relay", {"url": str(srv.make_url("")).rstrip("/"), "device_id": "mac1"})
    s = secrets or MemSecrets(token="mac1.secret", key=relay.b64e(KEY))
    return relay.RelayAgent(db, appmod.kv_get, appmod.kv_set, secret_store=s)


def test_not_configured_raises():
    a = relay.RelayAgent(db, appmod.kv_get, appmod.kv_set, secret_store=MemSecrets())
    assert not a.configured
    with pytest.raises(relay.RelayError):
        asyncio.run(a.cycle())


def test_push_pull_cycle_end_to_end():
    appmod.add_reading(77.7, time.time() - 30, source="scale")
    analysis = {"is_food": True, "meal_type": "lunch", "confidence": 0.9, "notes": "", "adjusted": [],
                "totals": {"kcal": 450, "protein_g": 25, "carbs_g": 50, "fat_g": 15, "fiber_g": 4},
                "items": [{"name": "pasta", "grams": 200, "kcal": 450, "protein_g": 25, "carbs_g": 50, "fat_g": 15, "fiber_g": 4}]}
    mid = food.store_meal(db, analysis, photos=None, caption="pasta")
    food.set_status(db, mid, "confirmed")
    fake = FakeRelay()

    async def go():
        async with TestServer(fake.app()) as srv:
            agent = agent_for(srv)
            first = await agent.cycle()

            # what the relay holds is ciphertext that only the key holder can read, bound to its sender
            seen = [relay.decrypt(KEY, r["device_id"], r["record_id"], r["nonce"], r["ciphertext"]) for r in fake.records]

            # the phone answers: a weight, an activity day, one forged and one garbage record
            now = int(time.time())
            for i, e in enumerate([env("weight", "hk-1", 100, ts=now - 600, weight_kg=78.4, fat_pct=21.0),
                                   env("activity_day", "day:2026-11-13", 100, day="2026-11-13", active_kcal=555, steps=8000)]):
                rid = f"phone-rec-{i:04d}"
                fake.records.append({**relay.encrypt(KEY, "phone1", rid, e), "seq": len(fake.records) + 1, "device_id": "phone1"})
            forged = relay.encrypt(KEY, "phone1", "phone-rec-9999", env("weight", "evil", 1, ts=now, weight_kg=99))
            fake.records.append({**forged, "record_id": "phone-rec-8888", "seq": len(fake.records) + 1, "device_id": "phone1"})
            fake.records.append({"record_id": "phone-rec-7777", "nonce": "AAAA", "ciphertext": "AAAA",
                                 "seq": len(fake.records) + 1, "device_id": "phone1"})
            second = await agent.cycle()
            third = await agent.cycle()
            return agent, first, seen, second, third
    agent, first, seen, second, third = asyncio.run(go())

    assert first == {"pulled": 0, "pushed": 2}
    assert sorted(e["type"] for e in seen) == ["meal", "weight"]
    assert next(e for e in seen if e["type"] == "weight")["data"]["weight_kg"] == 77.7
    assert next(e for e in seen if e["type"] == "meal")["data"]["items"][0]["name"] == "pasta"

    assert second == {"pulled": 2, "pushed": 0}                      # phone data in, nothing echoed back
    r = db.execute("SELECT * FROM readings WHERE source='applehealth'").fetchone()
    assert r["weight"] == 78.4 and r["fat_pct_m"] == 21.0
    assert db.execute("SELECT steps FROM activity_days").fetchone()[0] == 8000
    assert db.execute("SELECT COUNT(*) FROM readings WHERE sync_id='evil'").fetchone()[0] == 0   # forgery dropped
    assert agent.state["bad"] == 2
    assert third == {"pulled": 0, "pushed": 0}                       # cursors advanced, nothing replays
    assert appmod.kv_get("relay_cursor") == len(fake.records) and fake.acks[-1] == len(fake.records)
    assert agent.status()["pending"] == 0 and agent.state["last_error"] is None


def test_failed_push_loses_nothing_and_retries():
    appmod.add_reading(70.1, time.time(), source="scale")
    fake = FakeRelay()

    async def go():
        async with TestServer(fake.app()) as srv:
            agent = agent_for(srv)
            fake.fail_push = True
            with pytest.raises(relay.RelayError) as ei:
                await agent.cycle()
            stuck = appmod.kv_get("relay_pushed_seq", 0), len(fake.records)
            fake.fail_push = False
            ok = await agent.cycle()
            return ei.value.status, stuck, ok
    status, stuck, ok = asyncio.run(go())
    assert status == 500 and stuck == (0, 0) and ok["pushed"] == 1 and len(fake.records) == 1


def test_deletion_propagates_after_a_prior_send():
    rid = appmod.add_reading(70.2, time.time(), source="manual")
    fake = FakeRelay()

    async def go():
        async with TestServer(fake.app()) as srv:
            agent = agent_for(srv)
            await agent.cycle()
            db.execute("DELETE FROM readings WHERE id=?", (rid,))
            db.commit()
            await agent.cycle()
    asyncio.run(go())
    ops = [relay.decrypt(KEY, r["device_id"], r["record_id"], r["nonce"], r["ciphertext"])["op"] for r in fake.records]
    assert ops == ["upsert", "delete"]


def test_unauthorized_relay_reports_error_without_leaking_token():
    async def go():
        a = web.Application()
        a.add_routes([web.get("/v1/pull", lambda r: web.json_response({"error": "invalid token"}, status=401))])
        async with TestServer(a) as srv:
            agent = agent_for(srv, MemSecrets(token="mac1.TOPSECRET", key=relay.b64e(KEY)))
            with pytest.raises(relay.RelayError) as ei:
                await agent.cycle()
            return str(ei.value)
    msg = asyncio.run(go())
    assert "401" in msg and "TOPSECRET" not in msg
