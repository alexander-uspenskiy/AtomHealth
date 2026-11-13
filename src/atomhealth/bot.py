"""Telegram bot: send a photo (or several, or a text) of a meal, get calories and macros back.

Long polling over plain aiohttp (no public URL, no extra dependency). Everything user-tunable
(token, allowed IDs, auto-save, session window) is read through a `cfg()` callable on every use,
so changes made in the Settings UI apply immediately; token/enabled changes need `apply()`.
"""
import asyncio
import html
import json
import logging
import time

import aiohttp

from datetime import datetime

from . import advisor, food
from .llm import LLMError

log = logging.getLogger("atomhealth.bot")
API = "https://api.telegram.org"
ALBUM_WAIT = 1.5          # seconds to collect the photos of one Telegram album
MAX_FILE = 15 * 1024 * 1024
POLL_TIMEOUT = 25
SWEEP_EVERY = 15

HELP = ("<b>AtomHealth food bot</b>\n"
        "📸 Send a photo of your meal (add a caption like “200 g rice, homemade” for accuracy).\n"
        "➕ Send more photos or a note within a few minutes to add them to the same meal.\n"
        "✍️ Or just describe it: “2 eggs and toast”.\n\n"
        "/today – meals and calories so far today\n"
        "/advice – coaching tip for today\n"
        "/week – weekly review and calorie-target check\n"
        "/ask <question> – ask the coach about your diet\n"
        "/undo – delete the last meal with its photos and data\n"
        "/weight – your latest weight\n"
        "/help – this message")


class TelegramError(Exception):
    def __init__(self, msg, code=None):
        super().__init__(msg)
        self.code = code


class TgApi:
    """Minimal Telegram Bot API client."""

    def __init__(self, token, base=API):
        self.token, self.base, self._http = token, base, None

    async def start(self):
        self._http = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=POLL_TIMEOUT + 20))

    async def close(self):
        if self._http:
            await self._http.close()

    async def call(self, method, **params):
        async with self._http.post(f"{self.base}/bot{self.token}/{method}", json=params) as r:
            data = await r.json(content_type=None)
        if not data.get("ok"):
            raise TelegramError(data.get("description", "Telegram error"), data.get("error_code"))
        return data["result"]

    async def download(self, file_id) -> bytes:
        info = await self.call("getFile", file_id=file_id)
        if (info.get("file_size") or 0) > MAX_FILE:
            raise food.AnalysisError("that file is too large (15 MB max)")
        async with self._http.get(f"{self.base}/file/bot{self.token}/{info['file_path']}") as r:
            r.raise_for_status()
            return await r.read()


def esc(s):
    return html.escape(str(s), quote=False)


def kcal_fmt(v):
    return f"{v:,.0f}"


def render_meal(analysis, status, day_kcal, target):
    """HTML message for a meal. day_kcal = today's total including this meal."""
    t = analysis["totals"]
    mt = analysis["meal_type"]
    head = f"🍽 <b>{esc(mt.capitalize() if mt != 'unknown' else 'Meal')}</b> · <b>{kcal_fmt(t['kcal'])} kcal</b>"
    lines = [head, ""]
    for i in analysis["items"]:
        g = f" — {i['grams']:.0f} g" if i["grams"] else ""
        lines.append(f"• {esc(i['name'])}{g} · {kcal_fmt(i['kcal'])} kcal")
    lines.append("")
    lines.append(f"P {t['protein_g']:.0f} g · C {t['carbs_g']:.0f} g · F {t['fat_g']:.0f} g"
                 + (f" · fibre {t['fiber_g']:.0f} g" if t["fiber_g"] else ""))
    conf = f"Confidence {analysis['confidence'] * 100:.0f}%"
    lines.append(f"<i>{conf}" + (f" — {esc(analysis['notes'])}" if analysis["notes"] else "") + "</i>")
    day = f"Today: {kcal_fmt(day_kcal)}"
    if target:
        left = target - day_kcal
        day += f" / {kcal_fmt(target)} kcal ({kcal_fmt(abs(left))} {'left' if left >= 0 else 'over'})"
    else:
        day += " kcal"
    lines += ["", day]
    if status == "pending":
        lines += ["", "➕ Add photos or a note (e.g. “it was 300 g”) to refine this meal, then tap Save."]
    elif status == "confirmed":
        lines += ["", "✅ Saved"]
    else:
        lines += ["", "🗑 Discarded"]
    return "\n".join(lines)


def keyboard(meal_id, status):
    rows = []
    if status == "pending":
        rows.append([{"text": "✅ Save", "callback_data": f"save:{meal_id}"},
                     {"text": "🗑 Discard", "callback_data": f"del:{meal_id}"}])
    if status != "discarded":
        rows.append([{"text": "💡 Advice", "callback_data": f"tip:{meal_id}"}])
    return {"inline_keyboard": rows}


class TelegramBot:
    def __init__(self, db, *, cfg, target_kcal, latest_weight, kv_get, kv_set, plan=lambda: {},
                 context=lambda meal=None: None, notify=lambda: None, api_factory=TgApi, api_base=API):
        self.db, self.cfg, self.plan, self.context, self.notify = db, cfg, plan, context, notify
        self.target_kcal, self.latest_weight = target_kcal, latest_weight
        self.kv_get, self.kv_set = kv_get, kv_set
        self.api_factory, self.api_base = api_factory, api_base
        self.api = None
        self.state, self.username, self.error = "stopped", None, None
        self.last_update = 0
        self.contacts = {}      # unauthorised people who wrote to the bot: id -> {name, username, ts}
        self.sessions = {}      # chat_id -> {meal_id, msg_id, last}
        self._tasks, self._albums, self._locks = set(), {}, {}
        self._main = self._sweeper = None

    # ---------- lifecycle ----------
    def status(self):
        return {"state": self.state, "username": self.username, "error": self.error,
                "last_update": self.last_update,
                "contacts": [{"id": i, **{k: v for k, v in c.items() if k != "replied"}} for i, c in sorted(self.contacts.items(), key=lambda x: -x[1]["ts"])]}

    async def apply(self):
        """(Re)start according to the current settings."""
        await self.stop()
        c = self.cfg()
        if not (c["enabled"] and c["token"]):
            self.error = None
            return
        self.api = self.api_factory(c["token"], self.api_base)
        await self.api.start()
        self.state, self.error = "starting", None
        self._main = asyncio.create_task(self._run())
        self._sweeper = asyncio.create_task(self._sweep_loop())

    async def stop(self):
        for t in (self._main, self._sweeper, *self._tasks):
            if t:
                t.cancel()
        for t in (self._main, self._sweeper, *list(self._tasks)):
            if t:
                try:
                    await t
                except (asyncio.CancelledError, Exception):
                    pass
        self._main = self._sweeper = None
        self._tasks.clear()
        for a in self._albums.values():
            if a.get("timer"):
                a["timer"].cancel()
        self._albums.clear()
        if self.api:
            await self.api.close()
            self.api = None
        self.state, self.username = "stopped", None

    def _scrub(self, text):
        tok = self.cfg().get("token")
        return str(text).replace(tok, "***") if tok else str(text)

    def _spawn(self, coro):
        t = asyncio.create_task(self._safe(coro))
        self._tasks.add(t)
        t.add_done_callback(self._tasks.discard)

    async def _safe(self, coro):
        try:
            await coro
        except asyncio.CancelledError:
            raise
        except Exception as e:
            log.warning("bot handler failed: %s", self._scrub(e))

    async def _run(self):
        backoff = 2
        while True:
            try:
                if not self.username:
                    me = await self.api.call("getMe")
                    self.username = me.get("username")
                    self.state, self.error = "running", None
                offset = self.kv_get("tg_offset", 0)
                updates = await self.api.call("getUpdates", offset=offset, timeout=POLL_TIMEOUT,
                                              allowed_updates=["message", "callback_query"])
                self.state, self.error, backoff = "running", None, 2
                for u in updates:
                    offset = max(offset, u["update_id"] + 1)
                    self.last_update = int(time.time())
                    self._spawn(self.handle_update(u))
                if updates:
                    self.kv_set("tg_offset", offset)
            except asyncio.CancelledError:
                raise
            except TelegramError as e:
                if e.code in (401, 404):
                    self.state, self.error = "error", "Telegram rejected the bot token. Check it in Settings."
                    return
                self.state = "error"
                self.error = ("Another program is polling this bot (stop the other instance)."
                              if e.code == 409 else self._scrub(e))
                await asyncio.sleep(10 if e.code == 409 else backoff)
                backoff = min(backoff * 2, 30)
            except Exception as e:  # network trouble: keep trying
                self.state, self.error = "error", f"Connection problem: {self._scrub(e)}"
                await asyncio.sleep(backoff)
                backoff = min(backoff * 2, 30)

    # ---------- helpers ----------
    def _lock(self, chat_id):
        return self._locks.setdefault(chat_id, asyncio.Lock())

    def _allowed(self, user_id):
        return user_id in self.cfg()["allowed_ids"]

    def _status_of(self, meal_id):
        r = self.db.execute("SELECT status FROM meals WHERE id=?", (meal_id,)).fetchone()
        return r[0] if r else None

    def _session_open(self, s):
        return (s and time.time() - s["last"] < self.cfg()["session_minutes"] * 60
                and self._status_of(s["meal_id"]) == "pending")

    def _render_meal_row(self, meal_id):
        row = self.db.execute("SELECT raw_json, status, meal_type FROM meals WHERE id=?", (meal_id,)).fetchone()
        if not row:
            return None, None
        start = food.day_start()
        day = food.sum_meals(food.meals_between(self.db, start, start + 86400))["kcal"]
        analysis = json.loads(row["raw_json"])
        analysis["meal_type"] = row["meal_type"] or "unknown"
        if row["status"] == "pending":
            day += analysis["totals"]["kcal"]
        return render_meal(analysis, row["status"], day, self.target_kcal()), keyboard(meal_id, row["status"])

    async def _send(self, chat_id, text, **kw):
        return await self.api.call("sendMessage", chat_id=chat_id, text=text, parse_mode="HTML", **kw)

    async def _edit(self, chat_id, msg_id, text, markup=None):
        try:
            await self.api.call("editMessageText", chat_id=chat_id, message_id=msg_id, text=text,
                                parse_mode="HTML", reply_markup=markup or {"inline_keyboard": []})
        except TelegramError as e:
            if "not modified" not in str(e):
                raise

    async def _refresh_meal_message(self, chat_id, msg_id, meal_id):
        text, kb = self._render_meal_row(meal_id)
        if text:
            await self._edit(chat_id, msg_id, text, kb)

    # ---------- updates ----------
    async def handle_update(self, u):
        if "callback_query" in u:
            return await self._on_callback(u["callback_query"])
        m = u.get("message")
        if not m or (m.get("chat") or {}).get("type") != "private":
            return
        chat_id, frm = m["chat"]["id"], m.get("from") or {}
        uid, text = frm.get("id"), (m.get("text") or "").strip()
        if not self._allowed(uid):
            prev = self.contacts.get(uid, {})
            self.contacts[uid] = {"name": " ".join(filter(None, [frm.get("first_name"), frm.get("last_name")])) or "?",
                                  "username": frm.get("username"), "ts": int(time.time()),
                                  "replied": prev.get("replied", 0)}
            while len(self.contacts) > 5:
                self.contacts.pop(min(self.contacts, key=lambda k: self.contacts[k]["ts"]))
            # The only thing a stranger gets is their own ID (to put in Settings): on /start, or at most
            # once every 10 minutes for any other message, so the bot cannot be used to spam.
            now = int(time.time())
            if text.startswith("/start") or now - self.contacts[uid]["replied"] > 600:
                self.contacts[uid]["replied"] = now
                await self._send(chat_id, f"This is a private bot. Your Telegram ID is <code>{uid}</code>.\n"
                                          "To use it, add that ID in AtomHealth → Settings → Telegram bot.")
            return
        if text.startswith("/"):
            head, _, args = text.partition(" ")
            return await self._command(chat_id, head.split("@")[0].lower(), frm.get("first_name"), args)
        fid = None
        if m.get("photo"):
            fid = m["photo"][-1]["file_id"]
        elif (m.get("document") or {}).get("mime_type", "").startswith("image/"):
            fid = m["document"]["file_id"]
        caption = (m.get("caption") or text).strip()
        gid = m.get("media_group_id")
        if fid and gid:
            key = (chat_id, gid)
            a = self._albums.setdefault(key, {"files": [], "caption": "", "timer": None})
            a["files"].append(fid)
            a["caption"] = a["caption"] or caption
            if a["timer"]:
                a["timer"].cancel()
            a["timer"] = asyncio.get_running_loop().call_later(ALBUM_WAIT, lambda: self._spawn(self._flush_album(key)))
        elif fid or caption:
            await self._process(chat_id, [fid] if fid else [], caption)

    async def _flush_album(self, key):
        a = self._albums.pop(key, None)
        if a:
            await self._process(key[0], a["files"], a["caption"])

    def welcome_text(self, name=None):
        """Greeting with today's calorie limit, macros and what is left."""
        who = f", {esc(name)}" if name else ""
        p = self.plan() or {}
        if not p.get("kcal"):
            return (f"👋 Welcome{who}!\n"
                    "I don't have a daily calorie limit for you yet. Set your height in the dashboard (Settings) "
                    "and take a weight reading, and I'll work one out.\n\n" + HELP)
        goal = {"lose": "lose weight", "maintain": "maintain weight", "gain": "gain weight"}.get(p.get("goal"), "")
        start = food.day_start()
        eaten = food.sum_meals(food.meals_between(self.db, start, start + 86400))["kcal"]
        left = p["kcal"] - eaten
        lines = [f"👋 Welcome{who}!", "",
                 f"🎯 Your daily limit: <b>{kcal_fmt(p['kcal'])} kcal</b>" + (f" (goal: {goal})" if goal else "")]
        m = {x["key"]: x["g"] for x in p.get("macros", [])}
        if m:
            lines.append(f"Protein {m.get('protein', 0)} g · Carbs {m.get('carbs', 0)} g · Fat {m.get('fat', 0)} g")
        lines.append(f"Today so far: {kcal_fmt(eaten)} kcal → {kcal_fmt(abs(left))} {'left' if left >= 0 else 'over'}")
        return "\n".join(lines) + "\n\n" + HELP

    async def _coach(self, chat_id, kind, question=None, meal=None, title=None, meal_id=None):
        """Send an LLM-written report (stats line computed in code + commentary from the model)."""
        note = await self._send(chat_id, "💭 Thinking…")
        try:
            snap = self.context(meal)
            if snap is None:
                return await self._edit(chat_id, note["message_id"], "I don't have enough data yet.")
            r = await advisor.report(kind, snap, question)
        except LLMError:
            return await self._edit(chat_id, note["message_id"],
                                    "⚠️ The AI model isn't reachable right now. Please try again in a minute.")
        text = (f"{title}\n" if title else "") + esc(r["headline"]) + "\n\n" + esc(r["text"])
        await self._edit(chat_id, note["message_id"], text)
        advisor.save_advice(self.db, kind, r, question=question, meal_id=meal_id, source="telegram")
        self.notify()                                   # lets the dashboard show it right away

    def _meal_analysis(self, meal_id):
        row = self.db.execute("SELECT raw_json, meal_type FROM meals WHERE id=?", (meal_id,)).fetchone()
        return {**json.loads(row[0]), "meal_type": row[1] or "unknown"} if row else None

    async def _command(self, chat_id, cmd, name=None, args=""):
        if cmd == "/advice":
            return await self._coach(chat_id, "day", title="💡 <b>Today's advice</b>")
        if cmd == "/week":
            return await self._coach(chat_id, "week", title="📊 <b>Weekly review</b>")
        if cmd == "/ask":
            if not args.strip():
                return await self._send(chat_id, "Ask me something, e.g. <code>/ask what should I eat for dinner?</code>")
            return await self._coach(chat_id, "ask", question=args.strip()[:500])
        if cmd == "/start":
            return await self._send(chat_id, self.welcome_text(name))
        if cmd == "/help":
            return await self._send(chat_id, HELP)
        if cmd == "/today":
            start = food.day_start()
            rows = food.meals_between(self.db, start, start + 86400)
            pending = food.meals_between(self.db, start, start + 86400, "pending")
            if not rows and not pending:
                return await self._send(chat_id, "Nothing logged today yet. Send me a photo of your meal 📸")
            lines = ["📅 <b>Today</b>"]
            for r in rows:
                lines.append(f"• {time.strftime('%H:%M', time.localtime(r['ts']))} "
                             f"{esc((r['meal_type'] or 'meal').capitalize())} — {kcal_fmt(r['kcal'])} kcal")
            t = food.sum_meals(rows)
            lines.append(f"\n<b>{kcal_fmt(t['kcal'])} kcal</b> · P {t['protein_g']:.0f} g · "
                         f"C {t['carbs_g']:.0f} g · F {t['fat_g']:.0f} g")
            tgt = self.target_kcal()
            if tgt:
                left = tgt - t["kcal"]
                lines.append(f"Target {kcal_fmt(tgt)} kcal → {kcal_fmt(abs(left))} {'left' if left >= 0 else 'over'}")
            if pending:
                lines.append(f"\n⏳ {len(pending)} meal(s) waiting for Save (not counted).")
            return await self._send(chat_id, "\n".join(lines))
        if cmd == "/undo":
            r = food.last_meal(self.db, "telegram")
            if not r:
                return await self._send(chat_id, "Nothing to undo.")
            dropped = advisor.purge_for_meal(self.db, r["id"], r["ts"])   # advice that counted this meal
            food.delete_meal(self.db, r["id"])            # meal, items and photos are gone for good
            s = self.sessions.get(chat_id)
            if s and s["meal_id"] == r["id"]:
                self.sessions.pop(chat_id)
                try:
                    await self._edit(chat_id, s["msg_id"], "🗑 Deleted.")
                except TelegramError:
                    pass
            self.notify()
            start = food.day_start()
            eaten = food.sum_meals(food.meals_between(self.db, start, start + 86400))["kcal"]
            tgt = self.target_kcal()
            bal = f"Today: {kcal_fmt(eaten)}"
            if tgt:
                left = tgt - eaten
                bal += f" / {kcal_fmt(tgt)} kcal ({kcal_fmt(abs(left))} {'left' if left >= 0 else 'over'})"
            else:
                bal += " kcal"
            note = f"\n🧹 Removed {dropped} advice message(s) that included it. /advice makes a fresh one." if dropped else ""
            return await self._send(chat_id, f"🗑 Deleted {esc((r['meal_type'] or 'meal'))} ({kcal_fmt(r['kcal'])} kcal) "
                                             f"with its photos and data.\n{bal}{note}")
        if cmd == "/weight":
            w = self.latest_weight()
            if not w:
                return await self._send(chat_id, "No weight reading yet.")
            return await self._send(chat_id, f"⚖️ <b>{w[0]:.1f} kg</b> · {time.strftime('%d %b %H:%M', time.localtime(w[1]))}")
        await self._send(chat_id, "Unknown command. /help")

    async def _on_callback(self, cq):
        if not self._allowed((cq.get("from") or {}).get("id")):
            return
        msg = cq.get("message") or {}
        chat_id, msg_id = (msg.get("chat") or {}).get("id"), msg.get("message_id")
        try:
            action, mid = (cq.get("data") or "").split(":")
            mid = int(mid)
        except ValueError:
            return await self.api.call("answerCallbackQuery", callback_query_id=cq["id"])
        if action == "tip":
            await self.api.call("answerCallbackQuery", callback_query_id=cq["id"], text="Thinking…")
            meal = self._meal_analysis(mid)
            if meal and chat_id:
                self._spawn(self._coach(chat_id, "meal", meal=meal, meal_id=mid, title="💡 <b>Advice for this meal</b>"))
            return
        cur = self._status_of(mid)
        if cur != "pending":
            toast = "Already " + (cur or "gone")
        else:
            food.set_status(self.db, mid, "confirmed" if action == "save" else "discarded")
            if action != "save":
                m = self.db.execute("SELECT ts FROM meals WHERE id=?", (mid,)).fetchone()
                if m:
                    advisor.purge_for_meal(self.db, mid, m["ts"])
            toast = "Saved ✓" if action == "save" else "Discarded"
            s = self.sessions.get(chat_id)
            if s and s["meal_id"] == mid:
                self.sessions.pop(chat_id)
        await self.api.call("answerCallbackQuery", callback_query_id=cq["id"], text=toast)
        self.notify()
        if chat_id and msg_id:
            await self._refresh_meal_message(chat_id, msg_id, mid)

    async def _process(self, chat_id, file_ids, caption):
        async with self._lock(chat_id):
            note = await self._send(chat_id, "🔍 Analysing…")
            await self.api.call("sendChatAction", chat_id=chat_id, action="typing")
            try:
                photos = [await self.api.download(f) for f in file_ids]
                s = self.sessions.get(chat_id)
                extending = bool(self._session_open(s))
                if extending:
                    meal_id = s["meal_id"]
                    await food.extend_meal(self.db, meal_id, photos, caption)
                else:
                    analysis = await food.analyze_meal(photos, caption)
                    if not analysis["is_food"]:
                        return await self._edit(chat_id, note["message_id"],
                                                "🤔 I couldn't find any food there. Send a photo of your meal "
                                                "or describe what you ate.")
                    meal_id = food.store_meal(self.db, analysis, photos=photos, caption=caption, source="telegram")
                if extending and s.get("msg_id"):  # old message loses its buttons, the new one carries them
                    try:
                        await self._edit(chat_id, s["msg_id"], "↪️ Updated below.")
                    except TelegramError:
                        pass
                self.sessions[chat_id] = {"meal_id": meal_id, "msg_id": note["message_id"], "last": time.time()}
                await self._refresh_meal_message(chat_id, note["message_id"], meal_id)
                self.notify()                           # dashboard History shows the meal right away
            except food.AnalysisError as e:
                await self._edit(chat_id, note["message_id"], f"⚠️ {esc(e)}")
            except LLMError:
                await self._edit(chat_id, note["message_id"],
                                 "⚠️ The AI model isn't reachable right now. Please try again in a minute.")
            except TelegramError as e:
                log.warning("telegram error: %s", self._scrub(e))
            except Exception as e:
                log.exception("meal processing failed")
                await self._edit(chat_id, note["message_id"], "⚠️ Something went wrong. Please try again.")

    async def _sweep_loop(self):
        while True:
            await asyncio.sleep(SWEEP_EVERY)
            try:
                await self.sweep()
                self._scheduled()
            except asyncio.CancelledError:
                raise
            except Exception as e:
                log.warning("sweep failed: %s", self._scrub(e))

    async def sweep(self):
        """End expired sessions; auto-save their meals when that setting is on."""
        c, now = self.cfg(), time.time()
        for chat_id, s in list(self.sessions.items()):
            if now - s["last"] < c["session_minutes"] * 60:
                continue
            self.sessions.pop(chat_id)
            if c["auto_save"] and self._status_of(s["meal_id"]) == "pending":
                food.set_status(self.db, s["meal_id"], "confirmed")
                await self._refresh_meal_message(chat_id, s["msg_id"], s["meal_id"])

    def _scheduled(self, now=None):
        """Once a day at the configured time: a daily summary (a weekly review on Sundays)."""
        c = self.cfg()
        if not c.get("daily_summary", True):
            return
        now = now or datetime.now()
        if now.strftime("%H:%M") < c.get("summary_time", "21:00"):
            return
        key = now.strftime("%Y-%m-%d")
        if self.kv_get("tg_last_summary") == key:
            return
        self.kv_set("tg_last_summary", key)       # first, so a slow model call can never double-send
        start = food.day_start(now.timestamp())
        kind = "week" if now.weekday() == 6 else "day"
        if kind == "day" and not food.meals_between(self.db, start, start + 86400):
            return                                  # nothing logged today: stay quiet
        title = "📊 <b>Weekly review</b>" if kind == "week" else "🌙 <b>Daily summary</b>"
        for uid in c["allowed_ids"]:
            self._spawn(self._coach(uid, kind, title=title))

    async def send_test(self):
        """Message every allowed chat; returns how many were reached."""
        sent = 0
        for uid in self.cfg()["allowed_ids"]:
            try:
                await self._send(uid, "✅ AtomHealth is connected. Send me a photo of your meal 📸")
                sent += 1
            except TelegramError:
                pass
        return sent
