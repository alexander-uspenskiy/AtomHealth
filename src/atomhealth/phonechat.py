"""Phone chat: the iPhone app's Chat tab, served by the very same bot logic as Telegram.

The Telegram bot talks to a small API object (`call`, `download`). `PhoneApi` is a drop-in for it that, instead of
Telegram, exchanges end-to-end encrypted envelopes with the phone through the relay (see relay.py):

    phone -> Mac   type "chat_in"   id = unique message id; data.kind is one of
        "text"      {text}                                  a message or a /command
        "photo"     {photo_id, idx, n, b64}                 one chunk (<= CHUNK_MAX bytes) of a resized JPEG
        "message"   {text, photos: [photo_id, ...]}         sent after its chunks: photos + caption (an album if >1)
        "callback"  {data, msg_id}                          a tap on an inline button of message msg_id
        "ping"      {}                                      "are you there?": answered at once with "presence"
    Mac -> phone   type "chat_out"  id = "m<message_id>" (an upsert with a higher version is an edit)
        data {mid, text (Telegram-HTML subset), buttons [[{text, data}]], ts}
        id "typing": data {typing_until}      id "toast": data {toast}
        id "presence": data {ts, ai}   the answer to a ping; ai = is the AI backend reachable (true/false/null=unknown)

So every command, the plain-words intent routing, meal analysis, albums, Save/Discard buttons, editing a message in
place, /undo ... work on the phone exactly as in Telegram, with no second copy of the logic.
"""
import asyncio
import base64
import binascii
import collections
import re
import time

from .sync import ENVELOPE_VERSION

CHAT_ID = 1            # the one private chat with the phone
PHONE_UID = 1          # its "Telegram user id" (the allow-list of the phone bot is exactly this id)
CHUNK_MAX = 48_000     # bytes of JPEG per photo chunk the phone may send (relay record limit is ~64 KB of ciphertext)
MAX_CHUNKS = 64        # per photo
MAX_PHOTOS = 10        # per message
MAX_PHOTO_BYTES = 4_000_000
PARTIAL_TTL = 900      # seconds an incomplete photo is kept
_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
_SEEN = 1000


class PhoneChat:
    """Shared state between the relay agent (envelopes) and the phone bot (Telegram-shaped updates)."""

    def __init__(self, kv_get, kv_set):
        self.kv_get, self.kv_set = kv_get, kv_set
        self.updates = collections.deque()
        self._event = asyncio.Event()
        self.out = []                       # chat_out envelopes waiting to be pushed
        self.on_out = lambda: None          # relay agent hooks this to push at once
        self._partial = {}                  # photo_id -> {"n", "parts", "ts"}
        self._files = {}                    # file_id -> (bytes, ts), waiting for the bot's download()
        self._seen = collections.OrderedDict()
        self._versions = collections.OrderedDict()
        self._created = collections.OrderedDict()
        self._update_id = 0
        self.problems = 0
        self.ai_ok = None                   # reachability of the AI backend, kept fresh by the app (None = unknown)

    # ---------- phone -> bot ----------
    def ingest(self, env):
        """One decrypted chat_in envelope. Never raises; bad input is counted and dropped."""
        try:
            if env.get("op") != "upsert" or not isinstance(env.get("data"), dict):
                return
            sid = env["id"]
            if sid in self._seen:                       # a replayed page after a crash
                return
            self._seen[sid] = 1
            while len(self._seen) > _SEEN:
                self._seen.popitem(last=False)
            d, kind = env["data"], env["data"].get("kind")
            self._gc()
            if kind == "text":
                self._text(d)
            elif kind == "photo":
                self._chunk(d)
            elif kind == "message":
                self._message(d)
            elif kind == "callback":
                self._callback(d)
            elif kind == "ping":
                self._emit("presence", {"ts": int(time.time()), "ai": self.ai_ok})
            else:
                self.problems += 1
        except (KeyError, TypeError, ValueError, binascii.Error):
            self.problems += 1

    def _push_update(self, **u):
        self._update_id += 1
        self.updates.append({"update_id": self._update_id, **u})
        self._event.set()

    def _msg(self, **extra):
        return {"message_id": self._next_mid(), "chat": {"id": CHAT_ID, "type": "private"},
                "from": {"id": PHONE_UID, "first_name": "Phone"}, "date": int(time.time()), **extra}

    @staticmethod
    def _clean(text, limit=2000):
        return text.strip()[:limit] if isinstance(text, str) else ""

    def _text(self, d):
        text = self._clean(d.get("text"))
        if text:
            self._push_update(message=self._msg(text=text))

    def _chunk(self, d):
        pid, idx, n = d["photo_id"], d["idx"], d["n"]
        if (not isinstance(pid, str) or not _ID.match(pid) or isinstance(idx, bool) or isinstance(n, bool)
                or not isinstance(idx, int) or not isinstance(n, int) or not 1 <= n <= MAX_CHUNKS or not 0 <= idx < n):
            raise ValueError("bad chunk")
        raw = base64.b64decode(d["b64"], validate=True)
        if not raw or len(raw) > CHUNK_MAX:
            raise ValueError("bad chunk size")
        p = self._partial.setdefault(pid, {"n": n, "parts": {}, "ts": time.time()})
        if p["n"] != n:
            raise ValueError("inconsistent chunk count")
        p["parts"][idx] = raw
        if sum(map(len, p["parts"].values())) > MAX_PHOTO_BYTES:
            self._partial.pop(pid, None)
            raise ValueError("photo too large")

    def _take_photo(self, pid):
        p = self._partial.pop(pid, None) if isinstance(pid, str) else None
        if not p or len(p["parts"]) != p["n"]:
            return None
        fid = f"pc:{pid}"
        self._files[fid] = (b"".join(p["parts"][i] for i in range(p["n"])), time.time())
        return fid

    def _message(self, d):
        ids, caption = d.get("photos") or [], self._clean(d.get("text"), 1000)
        if not isinstance(ids, list) or not 1 <= len(ids) <= MAX_PHOTOS:
            raise ValueError("bad photo list")
        files = [self._take_photo(i) for i in ids]
        if not all(files):
            self.problems += 1
            self._send_error("⚠️ A photo did not arrive completely. Please send it again.")
            return
        group = str(self._update_id + 1) if len(files) > 1 else None
        for k, fid in enumerate(files):
            extra = {"photo": [{"file_id": fid}]}
            if caption and k == 0:
                extra["caption"] = caption
            if group:
                extra["media_group_id"] = group
            self._push_update(message=self._msg(**extra))

    def _callback(self, d):
        data, mid = d["data"], d["msg_id"]
        if not isinstance(data, str) or len(data) > 64 or isinstance(mid, bool) or not isinstance(mid, int):
            raise ValueError("bad callback")
        self._push_update(callback_query={
            "id": f"cb{self._update_id + 1}", "from": {"id": PHONE_UID}, "data": data,
            "message": {"message_id": mid, "chat": {"id": CHAT_ID, "type": "private"}}})

    def _gc(self):
        cut = time.time() - PARTIAL_TTL
        for k in [k for k, v in self._partial.items() if v["ts"] < cut]:
            del self._partial[k]
        for k in [k for k, v in self._files.items() if v[1] < cut]:
            del self._files[k]

    async def next_updates(self, timeout):
        if not self.updates:
            self._event.clear()
            try:
                await asyncio.wait_for(self._event.wait(), timeout)
            except asyncio.TimeoutError:
                return []
        out = list(self.updates)
        self.updates.clear()
        return out

    def take_file(self, file_id):
        f = self._files.pop(file_id, None)
        if f is None:
            raise KeyError("photo expired")
        return f[0]

    # ---------- bot -> phone ----------
    def _next_mid(self):
        n = self.kv_get("next_id", 1)
        self.kv_set("next_id", n + 1)
        return n

    def _emit(self, sid, data):
        now = time.time()
        v = max(int(now * 1000), self._versions.get(sid, 0) + 1)
        self._versions[sid] = v
        while len(self._versions) > _SEEN:
            self._versions.popitem(last=False)
        self.out.append({"v": ENVELOPE_VERSION, "type": "chat_out", "op": "upsert", "id": sid, "version": v,
                         "updated_at": int(now), "data": data})
        self.on_out()

    @staticmethod
    def _buttons(markup):
        rows = (markup or {}).get("inline_keyboard") or []
        return [[{"text": str(b["text"]), "data": str(b["callback_data"])} for b in row if "callback_data" in b]
                for row in rows]

    def send(self, text, markup=None):
        mid = self._next_mid()
        ts = int(time.time())
        self._created[mid] = ts
        while len(self._created) > _SEEN:
            self._created.popitem(last=False)
        self._emit(f"m{mid}", {"mid": mid, "text": text, "buttons": self._buttons(markup), "ts": ts})
        return mid

    def edit(self, mid, text, markup=None):
        self._emit(f"m{mid}", {"mid": mid, "text": text, "buttons": self._buttons(markup),
                               "ts": self._created.get(mid, int(time.time())), "edited": True})

    def _send_error(self, text):
        self.send(text)

    def typing(self):
        self._emit("typing", {"typing_until": int(time.time()) + 6})

    def toast(self, text):
        self._emit("toast", {"toast": str(text)[:100], "ts": int(time.time())})

    def drain(self):
        out, self.out = self.out, []
        return out

    def requeue(self, envs):
        self.out = envs + self.out


class PhoneApi:
    """The slice of the Telegram Bot API that `bot.TelegramBot` uses, answered locally."""

    def __init__(self, chat):
        self.chat = chat

    async def start(self):
        pass

    async def close(self):
        pass

    async def call(self, method, **p):
        c = self.chat
        if method == "getMe":
            return {"username": "phone"}
        if method == "getUpdates":
            return await c.next_updates(p.get("timeout", 25))
        if method == "sendMessage":
            return {"message_id": c.send(p["text"], p.get("reply_markup"))}
        if method == "editMessageText":
            c.edit(p["message_id"], p["text"], p.get("reply_markup"))
            return {}
        if method == "sendChatAction":
            c.typing()
        elif method == "answerCallbackQuery" and p.get("text"):
            c.toast(p["text"])
        return {}

    async def download(self, file_id):
        return self.chat.take_file(file_id)
