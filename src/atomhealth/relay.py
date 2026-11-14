"""Mac-side agent for the Cloudflare relay (see docs/ARCHITECTURE-sync.md).

Every cycle: pull records other devices pushed -> decrypt -> merge into SQLite (sync.apply_batch),
then collect local changes -> encrypt -> push. The relay only ever sees ciphertext; the 256-bit data
key and the device token live in the macOS Keychain (or RELAY_KEY / RELAY_TOKEN env vars for headless use).

CLI:  python -m atomhealth.relay {pair,keygen,export-key,import-key,status,sync}
"""
import argparse
import asyncio
import base64
import getpass
import json
import os
import secrets
import sys
import time
from urllib.parse import urlparse

import aiohttp
from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305

from . import sync

KEYRING_SERVICE = "atomhealth-relay"
AAD_PREFIX = b"atomhealth-v1|"
PUSH_BATCH = 50          # relay limit
PULL_PAGE = 100
LOOPBACK = ("localhost", "127.0.0.1", "::1")


class RelayError(Exception):
    def __init__(self, message, status=None):
        super().__init__(message)
        self.status = status


class CryptoError(Exception):
    pass


# ---------------------------------------------------------------------------- secrets
class SecretStore:
    """Env var RELAY_<NAME> wins (headless/CI); otherwise the macOS Keychain via `keyring`."""

    def get(self, name):
        v = os.environ.get(f"RELAY_{name.upper()}")
        if v:
            return v
        try:
            import keyring
            return keyring.get_password(KEYRING_SERVICE, name)
        except Exception:
            return None

    def set(self, name, value):
        try:
            import keyring
            keyring.set_password(KEYRING_SERVICE, name, value)
        except Exception as e:
            raise RelayError(f"cannot store {name} in the keychain ({e}); set RELAY_{name.upper()} instead") from e


# ---------------------------------------------------------------------------- crypto
def b64e(b: bytes) -> str:
    return base64.b64encode(b).decode()


def b64d(s: str) -> bytes:
    return base64.b64decode(s.replace("-", "+").replace("_", "/"), validate=False)


def new_key() -> bytes:
    return os.urandom(32)


def new_record_id() -> str:
    return secrets.token_urlsafe(16)


def _aad(device_id, record_id):
    return AAD_PREFIX + device_id.encode() + b"|" + record_id.encode()


def encrypt(key: bytes, device_id: str, record_id: str, envelope: dict) -> dict:
    """AEAD with (device_id, record_id) bound as associated data so the relay cannot swap ciphertexts."""
    nonce = os.urandom(12)
    ct = ChaCha20Poly1305(key).encrypt(nonce, json.dumps(envelope, separators=(",", ":")).encode(), _aad(device_id, record_id))
    return {"record_id": record_id, "nonce": b64e(nonce), "ciphertext": b64e(ct)}


def decrypt(key: bytes, device_id: str, record_id: str, nonce_b64: str, ct_b64: str) -> dict:
    try:
        pt = ChaCha20Poly1305(key).decrypt(b64d(nonce_b64), b64d(ct_b64), _aad(device_id, record_id))
        return json.loads(pt)
    except (InvalidTag, ValueError) as e:  # tampered, wrong key, wrong binding, or garbage
        raise CryptoError("record failed authentication") from e


# ---------------------------------------------------------------------------- HTTP client
def check_url(url):
    u = urlparse(url)
    if u.scheme != "https" and not (u.scheme == "http" and u.hostname in LOOPBACK):
        raise RelayError("relay URL must be https (http is allowed only for localhost)")
    if not u.hostname:
        raise RelayError("bad relay URL")
    return url.rstrip("/")


class RelayClient:
    def __init__(self, url, token=None, session=None):
        self.url = check_url(url)
        self.token = token
        self._session = session
        self._own_session = session is None

    async def _s(self):
        if self._session is None:
            self._session = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=30))
        return self._session

    async def close(self):
        if self._own_session and self._session is not None:
            await self._session.close()
            self._session = None

    async def _req(self, method, path, headers=None, **kw):
        h = dict(headers or {})
        if self.token:
            h["authorization"] = f"Bearer {self.token}"
        try:
            async with (await self._s()).request(method, self.url + path, headers=h, **kw) as r:
                body = await r.json(content_type=None) if r.content_length != 0 else {}
                if r.status >= 400:
                    raise RelayError(f"relay answered {r.status}: {body.get('error', '') if isinstance(body, dict) else ''}", r.status)
                return body
        except (aiohttp.ClientError, asyncio.TimeoutError) as e:
            raise RelayError(f"relay unreachable: {type(e).__name__}") from e

    async def pair(self, admin_code, name):
        return await self._req("POST", "/v1/pair", headers={"x-admin-code": admin_code}, json={"name": name})

    async def push(self, records):
        return await self._req("POST", "/v1/push", json={"records": records})

    async def pull(self, since, limit=PULL_PAGE):
        return await self._req("GET", f"/v1/pull?since={int(since)}&limit={int(limit)}")

    async def ack(self, cursor):
        return await self._req("POST", "/v1/ack", json={"cursor": int(cursor)})


# ---------------------------------------------------------------------------- agent
class RelayAgent:
    def __init__(self, db, kv_get, kv_set, secret_store=None, interval=300, session=None):
        self.db, self.kv_get, self.kv_set = db, kv_get, kv_set
        self.secrets = secret_store or SecretStore()
        self.interval = interval
        self._session = session
        self._lock = asyncio.Lock()
        self._failures = 0
        self.state = {"last_ok": None, "last_error": None, "pulled": 0, "pushed": 0, "bad": 0}

    def _creds(self):
        cfg = self.kv_get("relay") or {}
        token, key = self.secrets.get("token"), self.secrets.get("key")
        if not (cfg.get("url") and cfg.get("device_id") and token and key):
            return None
        raw = b64d(key)
        if len(raw) != 32:
            raise RelayError("stored data key must be 32 bytes")
        return cfg["url"], cfg["device_id"], token, raw

    @property
    def configured(self):
        try:
            return self._creds() is not None
        except RelayError:
            return False

    def status(self):
        cfg = self.kv_get("relay") or {}
        return {"configured": self.configured, "url": cfg.get("url"), "device_id": cfg.get("device_id"),
                "cursor": self.kv_get("relay_cursor", 0), "pushed_seq": self.kv_get("relay_pushed_seq", 0),
                "pending": max(0, sync.outbox_max(self.db) - self.kv_get("relay_pushed_seq", 0)), **self.state}

    async def cycle(self):
        """One pull + push. Raises RelayError on transport/auth problems (state is only advanced after success)."""
        creds = self._creds()
        if creds is None:
            raise RelayError("relay is not configured (run: python -m atomhealth.relay pair)")
        url, device_id, token, key = creds
        async with self._lock:
            client = RelayClient(url, token, self._session)
            try:
                pulled = await self._pull(client, key)
                pushed = await self._push(client, device_id, key)
            finally:
                await client.close()
        self.state.update(last_ok=int(time.time()), last_error=None)
        return {"pulled": pulled, "pushed": pushed}

    async def _pull(self, client, key):
        since, total = self.kv_get("relay_cursor", 0), 0
        while True:
            page = await client.pull(since, PULL_PAGE)
            envs, bad = [], 0
            for rec in page.get("records", []):
                try:
                    envs.append(decrypt(key, rec["device_id"], rec["record_id"], rec["nonce"], rec["ciphertext"]))
                except (CryptoError, KeyError):
                    bad += 1
            if envs:
                counts = sync.apply_batch(self.db, envs)
                total += counts["applied"] + counts["merged"]
                sync.log(self.db, "pull", None, len(envs), "ok", json.dumps(counts))
            if bad:
                self.state["bad"] += bad
                sync.log(self.db, "pull", None, bad, "undecryptable", "wrong key or tampered records skipped")
            nxt = page.get("next_seq", since)
            if nxt > since:  # persist locally first, then tell the relay; a lost ack only delays cleanup
                self.kv_set("relay_cursor", nxt)
                await client.ack(nxt)
            if not page.get("has_more") or nxt <= since:
                break
            since = nxt
        self.state["pulled"] += total
        return total

    async def _push(self, client, device_id, key):
        after, total = self.kv_get("relay_pushed_seq", 0), 0
        while True:
            envs, nxt = sync.collect(self.db, after, PUSH_BATCH)
            if envs:
                await client.push([encrypt(key, device_id, new_record_id(), e) for e in envs])
                sync.mark_sent(self.db, envs)
                sync.log(self.db, "push", None, len(envs), "ok")
                total += len(envs)
            if nxt > after:
                self.kv_set("relay_pushed_seq", nxt)  # only after the relay accepted the batch
            if nxt <= after or (not envs and nxt >= sync.outbox_max(self.db)):
                break
            after = nxt
        self.state["pushed"] += total
        return total

    async def run(self):
        """Background loop: sync on a timer, sooner when local changes appear, back off on errors."""
        while True:
            try:
                await self.cycle()
                self._failures = 0
                wait = self.interval
            except RelayError as e:
                self._failures += 1
                self.state["last_error"] = str(e)
                sync.log(self.db, "cycle", None, 0, "error", str(e))
                wait = min(900, 15 * 2 ** min(self._failures, 6))
            except Exception as e:  # never let the loop die
                self._failures += 1
                self.state["last_error"] = f"{type(e).__name__}: {e}"
                wait = 300
            deadline = time.monotonic() + wait
            while time.monotonic() < deadline:
                await asyncio.sleep(10)
                if self.configured and sync.outbox_max(self.db) > self.kv_get("relay_pushed_seq", 0):
                    break


# ---------------------------------------------------------------------------- CLI
def _app():
    from . import app  # heavy import (opens the DB), only needed by the CLI
    return app


def _cmd_pair(a):
    code = os.environ.get("RELAY_ADMIN_CODE")
    if a.admin_code_file:
        code = open(a.admin_code_file).read().strip()
    if not code:
        code = getpass.getpass("Relay admin code: ")
    app, store = _app(), SecretStore()

    async def go():
        c = RelayClient(a.url)
        try:
            return await c.pair(code, a.name)
        finally:
            await c.close()
    res = asyncio.run(go())
    store.set("token", res["token"])
    app.kv_set("relay", {"url": check_url(a.url), "device_id": res["device_id"]})
    print(f"Paired as device {res['device_id']} ({a.name}). Token stored in the keychain.")
    if not store.get("key"):
        print("No data key yet: run `keygen` here, or `import-key` with the key created on the phone.")


def _cmd_keygen(a):
    store = SecretStore()
    if store.get("key") and not a.force:
        sys.exit("A data key already exists. Use --force to replace it (this makes old relay records unreadable).")
    store.set("key", b64e(new_key()))
    print("Data key generated and stored in the keychain.")


def _cmd_export_key(a):
    key = SecretStore().get("key")
    if not key:
        sys.exit("No data key stored.")
    print("WARNING: this key decrypts all synced health data. Do not share or store it in plain text.", file=sys.stderr)
    print(key)


def _cmd_import_key(a):
    key = getpass.getpass("Base64 data key: ").strip()
    if len(b64d(key)) != 32:
        sys.exit("The key must decode to exactly 32 bytes.")
    SecretStore().set("key", key)
    print("Data key stored in the keychain.")


def _agent():
    app = _app()
    return RelayAgent(app.db, app.kv_get, app.kv_set)


def _cmd_status(a):
    print(json.dumps(_agent().status(), indent=2))


def _cmd_sync(a):
    print(json.dumps(asyncio.run(_agent().cycle())))


def main(argv=None):
    p = argparse.ArgumentParser(prog="python -m atomhealth.relay", description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    pp = sub.add_parser("pair", help="register this Mac with the relay (needs the admin code)")
    pp.add_argument("--url", required=True)
    pp.add_argument("--name", default="mac")
    pp.add_argument("--admin-code-file")
    pp.set_defaults(fn=_cmd_pair)
    kp = sub.add_parser("keygen", help="create the 256-bit data key (stored in the keychain)")
    kp.add_argument("--force", action="store_true")
    kp.set_defaults(fn=_cmd_keygen)
    sub.add_parser("export-key", help="print the data key (for pairing the phone)").set_defaults(fn=_cmd_export_key)
    sub.add_parser("import-key", help="store a data key created elsewhere").set_defaults(fn=_cmd_import_key)
    sub.add_parser("status").set_defaults(fn=_cmd_status)
    sub.add_parser("sync", help="run one pull+push cycle now").set_defaults(fn=_cmd_sync)
    a = p.parse_args(argv)
    try:
        a.fn(a)
    except RelayError as e:
        sys.exit(f"error: {e}")


if __name__ == "__main__":
    main()
