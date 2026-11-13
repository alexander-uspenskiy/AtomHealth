"""AtomHealth: BLE listener + SQLite + web dashboard + Apple Health feed.

  .venv/bin/python app.py              # dashboard on http://localhost:8765
  .venv/bin/python app.py --lan        # also reachable from your phone (Health feed only)
  .venv/bin/python app.py --no-ble     # no scale (testing / manual entry)
"""
import argparse
import asyncio
import csv
import io
import json
import os
import re
import secrets
import sqlite3
import time
from datetime import datetime
from pathlib import Path

import aiohttp
from aiohttp import web

from . import advisor, bodycomp, bot as tgbot, config, food
from .llm import LLMError

PKG_DIR = Path(__file__).resolve().parent            # src/atomhealth
STATIC_DIR = PKG_DIR / "static"
PROJECT_ROOT = PKG_DIR.parents[1]                    # repo root (src layout)
DATA_DIR = Path(os.environ.get("ATOMHEALTH_DATA_DIR", PROJECT_ROOT / "data"))
DATA_DIR.mkdir(parents=True, exist_ok=True)
DB_PATH = Path(os.environ.get("WEIGHT_DB", DATA_DIR / "weight.db"))
SIG = bytes.fromhex("65f4dd2144")  # trailing payload bytes of this scale's adverts
STABLE_SECS = 3.0
MIN_KG = 20.0
MAX_JUMP = 0.20  # ignore a reading that differs from the previous one by more than this fraction
SCAN_STALL_SECS = 120.0  # restart the BLE scan after this long with no advertisements

DEFAULT_PROFILE = {
    "height_cm": 174, "age": 30, "birthdate": None, "sex": "male",
    "target_weight": None, "target_fat_pct": None, "target_date": None,
    "activity": 1.375, "diet_goal": "auto", "diet_pace": None, "diet_style": "balanced",
    "special_requirements": "",
}

# ---------- storage ----------
db = sqlite3.connect(DB_PATH, check_same_thread=False)
db.row_factory = sqlite3.Row
db.executescript("""
CREATE TABLE IF NOT EXISTS readings(
  id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, weight REAL NOT NULL,
  impedance INTEGER, source TEXT DEFAULT 'scale', synced INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS kv(k TEXT PRIMARY KEY, v TEXT);
CREATE TABLE IF NOT EXISTS meals(
  id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, caption TEXT,
  meal_type TEXT, kcal REAL, protein_g REAL, carbs_g REAL, fat_g REAL, fiber_g REAL,
  confidence REAL, status TEXT NOT NULL DEFAULT 'pending',  -- pending | confirmed | discarded
  source TEXT DEFAULT 'telegram', raw_json TEXT);
CREATE TABLE IF NOT EXISTS meal_items(
  id INTEGER PRIMARY KEY AUTOINCREMENT, meal_id INTEGER NOT NULL REFERENCES meals(id) ON DELETE CASCADE,
  name TEXT NOT NULL, grams REAL, kcal REAL, protein_g REAL, carbs_g REAL, fat_g REAL);
CREATE INDEX IF NOT EXISTS meals_ts ON meals(ts);
CREATE TABLE IF NOT EXISTS advice(
  id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, day TEXT NOT NULL, kind TEXT NOT NULL,
  question TEXT, headline TEXT, text TEXT, used_llm INTEGER DEFAULT 1, meal_id INTEGER, source TEXT, basis TEXT);
CREATE INDEX IF NOT EXISTS advice_day ON advice(day);
""")
if "basis" not in {r["name"] for r in db.execute("PRAGMA table_info(advice)")}:
    db.execute("ALTER TABLE advice ADD COLUMN basis TEXT")  # what the day's meals looked like when it was written
# meal photos live in the DB as reduced JPEG blobs (one file to back up). Drop an empty pre-release layout.
if (cols := {r["name"] for r in db.execute("PRAGMA table_info(meal_photos)")}) and "data" not in cols:
    if db.execute("SELECT COUNT(*) FROM meal_photos").fetchone()[0] == 0:
        db.execute("DROP TABLE meal_photos")
db.executescript("""
CREATE TABLE IF NOT EXISTS meal_photos(
  id INTEGER PRIMARY KEY AUTOINCREMENT, meal_id INTEGER NOT NULL REFERENCES meals(id) ON DELETE CASCADE,
  idx INTEGER NOT NULL, mime TEXT NOT NULL DEFAULT 'image/jpeg', data BLOB NOT NULL,
  UNIQUE(meal_id, idx));
""")
db.execute("PRAGMA foreign_keys=ON")
food.retag_meals(db)


def kv_get(k, default=None):
    r = db.execute("SELECT v FROM kv WHERE k=?", (k,)).fetchone()
    return json.loads(r["v"]) if r else default


def kv_set(k, v):
    db.execute("INSERT OR REPLACE INTO kv VALUES(?,?)", (k, json.dumps(v)))
    db.commit()


def age_at(birthdate, ts):
    try:
        b = datetime.fromisoformat(birthdate)
    except (TypeError, ValueError):
        return None
    d = datetime.fromtimestamp(ts)
    return d.year - b.year - ((d.month, d.day) < (b.month, b.day))


def profile():
    p = {**DEFAULT_PROFILE, **kv_get("profile", {})}
    a = age_at(p.get("birthdate"), time.time())
    if a is not None:
        p["age"] = a
    return p


def token():
    t = kv_get("health_token")
    if not t:
        t = secrets.token_urlsafe(16)
        kv_set("health_token", t)
    return t


def reading_dict(r, prof):
    d = {"id": r["id"], "ts": r["ts"], "weight": r["weight"], "impedance": r["impedance"],
         "source": r["source"], "synced": bool(r["synced"])}
    a = age_at(prof.get("birthdate"), r["ts"])  # age at the time of the reading
    d.update(bodycomp.compute(r["weight"], {**prof, "age": a if a is not None else prof["age"]}))
    return d


def add_reading(weight, ts=None, impedance=None, source="scale"):
    cur = db.execute("INSERT INTO readings(ts,weight,impedance,source) VALUES(?,?,?,?)",
                     (int(ts or time.time()), round(weight, 2), impedance, source))
    db.commit()
    return cur.lastrowid


# ---------- live state / BLE ----------
live = {"weight": None, "ts": 0, "stable": False, "ble": "off", "last_saved": None}
subscribers = set()


def publish(event):
    for q in list(subscribers):
        q.put_nowait(event)


def decode(adv):
    for cid, data in adv.manufacturer_data.items():
        if cid & 0xFF == 0xC0 and len(data) == 13 and data.endswith(SIG):
            return data
    return None


async def ble_task():
    from bleak import BleakScanner
    st = {"w": None, "since": 0.0, "armed": False, "any": time.time()}

    def cb(dev, adv):
        st["any"] = time.time()  # any advertisement at all proves the scanner is alive
        data = decode(adv)
        if not data:
            return
        now = time.time()
        w = int.from_bytes(data[0:2], "big") / 100
        imp = int.from_bytes(data[2:4], "big")
        live["ts"] = now
        if w != st["w"]:
            # Only a *change* proves a fresh weigh-in (the scale keeps re-broadcasting
            # its last value when idle, which must not be saved again).
            if st["w"] is not None:
                st["armed"] = True
            st["w"], st["since"] = w, now
            live.update(weight=w, stable=False)
            publish({"type": "live", **live})
        elif w >= MIN_KG and st["armed"] and now - st["since"] >= STABLE_SECS:
            st["armed"] = False
            live["stable"] = True
            last = latest_weight()
            if last and abs(w - last[0]) / last[0] > MAX_JUMP:  # e.g. a bag or a child on the scale
                print(f"BLE: ignoring implausible reading {w} kg (last {last[0]} kg)", flush=True)
                publish({"type": "live", **live})
                return
            rid = add_reading(w, now, imp)
            live["last_saved"] = rid
            publish({"type": "saved", "id": rid, **live})

    while True:
        try:
            live["ble"] = "scanning"
            st["any"] = time.time()
            publish({"type": "live", **live})
            async with BleakScanner(cb):
                while True:
                    await asyncio.sleep(5)
                    if live["ts"] and time.time() - live["ts"] > 60 and live["weight"] is not None:
                        live.update(weight=None, stable=False)
                        publish({"type": "live", **live})
                    # Watchdog: CoreBluetooth can silently stop delivering callbacks on a
                    # long-running scan. Nearby devices normally advertise constantly, so
                    # prolonged total silence means the scan is dead: restart it.
                    if time.time() - st["any"] > SCAN_STALL_SECS:
                        print(f"BLE: no advertisements for {SCAN_STALL_SECS:.0f}s, restarting scan", flush=True)
                        live["ble"] = "restarting"
                        publish({"type": "live", **live})
                        break
            await asyncio.sleep(1)
        except Exception as e:  # Bluetooth off, permission, etc.
            live["ble"] = f"error: {e}"
            publish({"type": "live", **live})
            await asyncio.sleep(10)


# ---------- HTTP ----------
def local_only(request):
    if request.app["lan"] and request.remote not in ("127.0.0.1", "::1"):
        raise web.HTTPForbidden(text="dashboard is local-only; use /api/health/* with the token")


def health_auth(request):
    if request.query.get("token") != token():
        raise web.HTTPUnauthorized(text="bad token")


async def index(request):
    local_only(request)
    return web.FileResponse(STATIC_DIR / "index.html")


async def state(request):
    local_only(request)
    prof = profile()
    rows = db.execute("SELECT * FROM readings ORDER BY ts").fetchall()
    return web.json_response({
        "profile": prof, "healthy_range": bodycomp.healthy_range(prof),
        "optimal": bodycomp.optimal(prof), "ref": bodycomp.reference(prof),
        "nutrition": bodycomp.nutrition(prof, rows[-1]["weight"] if rows else None),
        "readings": [reading_dict(r, prof) for r in rows],
        "live": live, "health_token": token(), "advice": advisor.feed(db),
        "meals": meal_history(),
    })


def meal_history(limit=200):
    """Logged meals (newest first, discarded ones left out) with their items and photo count."""
    out = []
    for m in db.execute("SELECT * FROM meals WHERE status!='discarded' ORDER BY ts DESC, id DESC LIMIT ?", (limit,)):
        items = db.execute("SELECT name, grams, kcal FROM meal_items WHERE meal_id=? ORDER BY id", (m["id"],)).fetchall()
        out.append({"id": m["id"], "ts": m["ts"], "type": m["meal_type"], "caption": m["caption"], "status": m["status"],
                    "kcal": m["kcal"], "protein_g": m["protein_g"], "carbs_g": m["carbs_g"], "fat_g": m["fat_g"],
                    "fiber_g": m["fiber_g"], "source": m["source"], "photos": food.meal_photo_count(db, m["id"]),
                    "items": [{"name": i["name"], "grams": i["grams"], "kcal": i["kcal"]} for i in items]})
    return out


async def set_profile(request):
    local_only(request)
    body = await request.json()
    p = profile()
    for k in DEFAULT_PROFILE:
        if k in body:
            v = body[k]
            if k in ("height_cm", "age", "target_weight", "target_fat_pct", "activity", "diet_pace"):
                v = float(v) if v not in (None, "") else None
            if k == "special_requirements":
                v = str(v or "").strip()[:1000]
            p[k] = (v or None) if k in ("target_date", "birthdate") else v
    kv_set("profile", p)
    return web.json_response(p)


async def post_reading(request):
    local_only(request)
    b = await request.json()
    w = float(b["weight"])
    if not (20 <= w <= 300):
        raise web.HTTPBadRequest(text="weight out of range")
    ts = b.get("ts")
    if isinstance(ts, str):
        ts = datetime.fromisoformat(ts).timestamp()
    return web.json_response({"id": add_reading(w, ts, source="manual")})


async def import_readings(request):
    """Backfill history. Body: CSV text with header containing a date/time column
    and a weight column (e.g. an export from the scale's app)."""
    local_only(request)
    text = (await request.text()).strip()
    rows = list(csv.DictReader(io.StringIO(text)))
    if not rows:
        raise web.HTTPBadRequest(text="empty file")
    keys = {k.lower().strip(): k for k in rows[0]}
    dk = next((keys[k] for k in keys if "date" in k or "time" in k), None)
    wk = next((keys[k] for k in keys if "weight" in k or k in ("kg", "wt")), None)
    if not dk or not wk:
        raise web.HTTPBadRequest(text="need a date/time column and a weight column")
    existing = {(r["ts"] // 60, round(r["weight"], 1)) for r in db.execute("SELECT ts, weight FROM readings")}
    added = skipped = 0
    for r in rows:
        try:
            w = float(str(r[wk]).replace(",", ".").split()[0])
            raw = r[dk].strip()
            try:
                ts = datetime.fromisoformat(raw).timestamp()
            except ValueError:
                ts = None
                for f in ("%d/%m/%Y %H:%M", "%m/%d/%Y %H:%M", "%d/%m/%Y", "%m/%d/%Y", "%Y/%m/%d %H:%M", "%Y-%m-%d"):
                    try:
                        ts = datetime.strptime(raw, f).timestamp(); break
                    except ValueError:
                        pass
                if ts is None:
                    raise ValueError
            if not 20 <= w <= 300 or (int(ts) // 60, round(w, 1)) in existing:
                skipped += 1; continue
            add_reading(w, ts, source="import"); added += 1
        except (ValueError, KeyError, IndexError):
            skipped += 1
    return web.json_response({"added": added, "skipped": skipped})


async def del_reading(request):
    local_only(request)
    db.execute("DELETE FROM readings WHERE id=?", (int(request.match_info["id"]),))
    db.commit()
    return web.json_response({"ok": True})


async def export_csv(request):
    local_only(request)
    prof = profile()
    rows = [reading_dict(r, prof) for r in db.execute("SELECT * FROM readings ORDER BY ts")]
    out = io.StringIO()
    cols = ["id", "ts", "weight", "bmi", "fat_pct", "fat_kg", "lean_kg", "muscle_kg", "water_pct", "bmr", "impedance", "source"]
    w = csv.writer(out)
    w.writerow(["datetime"] + cols)
    for r in rows:
        w.writerow([datetime.fromtimestamp(r["ts"]).isoformat(sep=" ")] + [r.get(c) for c in cols])
    return web.Response(text=out.getvalue(), content_type="text/csv",
                        headers={"Content-Disposition": "attachment; filename=weight.csv"})


async def events(request):
    local_only(request)
    resp = web.StreamResponse(headers={"Content-Type": "text/event-stream", "Cache-Control": "no-cache"})
    await resp.prepare(request)
    q = asyncio.Queue()
    subscribers.add(q)
    try:
        await resp.write(f"data: {json.dumps({'type': 'live', **live})}\n\n".encode())
        while True:
            try:
                ev = await asyncio.wait_for(q.get(), 20)
                await resp.write(f"data: {json.dumps(ev)}\n\n".encode())
            except asyncio.TimeoutError:
                await resp.write(b": ping\n\n")
    except (ConnectionResetError, asyncio.CancelledError):
        pass
    finally:
        subscribers.discard(q)
    return resp


# Apple Health feed: an iOS Shortcut polls /pending, logs samples, then POSTs /ack.
async def health_pending(request):
    health_auth(request)
    prof = profile()
    rows = db.execute("SELECT * FROM readings WHERE synced=0 ORDER BY ts").fetchall()
    items = []
    for r in rows:
        d = reading_dict(r, prof)
        items.append({
            "id": d["id"],
            "date": datetime.fromtimestamp(d["ts"]).astimezone().isoformat(timespec="seconds"),
            "weight_kg": d["weight"], "body_fat_pct": d.get("fat_pct"),
            "lean_mass_kg": d.get("lean_kg"), "bmi": d.get("bmi"),
        })
    return web.json_response(items)


async def health_ack(request):
    health_auth(request)
    body = await request.json() if request.can_read_body else {}
    ids = body.get("ids") if isinstance(body, dict) else body
    if ids is None:
        ids = request.query.get("ids", "").split(",")
    ids = [int(i) for i in ids if str(i).strip().isdigit()]
    db.executemany("UPDATE readings SET synced=1 WHERE id=?", [(i,) for i in ids])
    db.commit()
    return web.json_response({"acked": ids})


MAX_UPLOAD = 15 * 1024 * 1024


async def food_analyze(request):
    """POST multipart: photo (file, repeatable: one eating session), caption (text), meal_id (optional).
    With meal_id, the photos/caption are added to that still-pending meal and the whole session is
    re-analysed. Otherwise a new pending meal is stored."""
    local_only(request)
    photos, caption, meal_id = [], "", None
    if request.content_type == "multipart/form-data":
        async for part in await request.multipart():
            if part.name == "photo":
                data = bytes(await part.read(decode=False))
                if data:
                    photos.append(data)
                if len(data) > MAX_UPLOAD:
                    raise web.HTTPRequestEntityTooLarge(max_size=MAX_UPLOAD, actual_size=len(data))
                if len(photos) > food.MAX_PHOTOS:
                    return web.json_response({"error": f"at most {food.MAX_PHOTOS} photos per meal"}, status=422)
            elif part.name == "caption":
                caption = (await part.text())[:500]
            elif part.name == "meal_id":
                meal_id = (await part.text()).strip() or None
    else:
        body = await request.json()
        caption, meal_id = str(body.get("caption", ""))[:500], body.get("meal_id")
    try:
        if meal_id is not None:
            try:
                meal_id = int(meal_id)
            except (TypeError, ValueError):
                raise web.HTTPBadRequest(text="meal_id must be an integer")
            analysis = await food.extend_meal(db, meal_id, photos, caption)
            return web.json_response({"meal_id": meal_id, "analysis": analysis})
        analysis = await food.analyze_meal(photos, caption)
    except food.AnalysisError as e:
        return web.json_response({"error": str(e)}, status=422)
    except LLMError as e:
        return web.json_response({"error": str(e)}, status=503)
    if not analysis["is_food"]:
        return web.json_response({"meal_id": None, "analysis": analysis})
    mid = food.store_meal(db, analysis, photos=photos, caption=caption, source="api")
    return web.json_response({"meal_id": mid, "analysis": analysis})


async def food_photo(request):
    local_only(request)
    try:
        got = food.meal_photo(db, int(request.match_info["id"]), int(request.match_info["idx"]))
    except ValueError:
        raise web.HTTPBadRequest()
    if not got:
        raise web.HTTPNotFound()
    return web.Response(body=got[1], content_type=got[0], headers={"Cache-Control": "private, max-age=86400"})


# ---------- runtime settings (Settings tab) ----------
TIME_RE = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")
TOKEN_RE = re.compile(r"^\d{5,}:[\w-]{20,}$")


def parse_ids(v):
    if isinstance(v, str):
        v = [x for x in re.split(r"[,\s;]+", v) if x]
    ids = [int(x) for x in v or []]       # ValueError on junk -> 400 in the endpoint
    if len(ids) > 20:
        raise ValueError("at most 20 Telegram IDs")
    return sorted(set(ids))


def telegram_cfg():
    """Effective bot settings: the Settings tab (kv) wins over .env."""
    c = kv_get("telegram", {})
    token = c["token"] if "token" in c else os.environ.get("TELEGRAM_BOT_TOKEN", "")
    ids = c["allowed_ids"] if "allowed_ids" in c else parse_ids(os.environ.get("TELEGRAM_ALLOWED_IDS", ""))
    return {"enabled": bool(c.get("enabled", bool(token))), "token": token or "", "allowed_ids": set(ids),
            "auto_save": bool(c.get("auto_save", False)),
            "session_minutes": min(max(int(c.get("session_minutes", 10)), 1), 180),
            "daily_summary": bool(c.get("daily_summary", True)),
            "summary_time": c.get("summary_time") if TIME_RE.match(c.get("summary_time") or "") else "21:00"}


def settings_view(request):
    c, bot = telegram_cfg(), request.app["bot"]
    ai = config.llm_settings()
    return {"telegram": {"enabled": c["enabled"], "has_token": bool(c["token"]),
                         "token_hint": c["token"][-4:] if c["token"] else "",
                         "allowed_ids": sorted(c["allowed_ids"]), "auto_save": c["auto_save"],
                         "session_minutes": c["session_minutes"], "daily_summary": c["daily_summary"],
                         "summary_time": c["summary_time"], "status": bot.status()},
            "ai": {"base_url": ai["base_url"], "model": ai["model"], "custom": bool(kv_get("ai", {}))}}


def latest_weight():
    r = db.execute("SELECT weight, ts FROM readings ORDER BY ts DESC LIMIT 1").fetchone()
    return (r["weight"], r["ts"]) if r else None


def nutrition_plan():
    w = latest_weight()
    return bodycomp.nutrition(profile(), w[0] if w else None) or {}


def advice_snapshot(meal=None):
    plan = nutrition_plan()
    if not plan:
        return None
    w = latest_weight()
    return advisor.snapshot(db, profile(), plan, w[0] if w else None, meal=meal)


def target_kcal():
    return nutrition_plan().get("kcal")


async def post_advice(request):
    """POST {"kind": "day"|"week"|"ask", "q": "..."}: generate advice, keep it, show it on the Overview."""
    local_only(request)
    try:
        body = await request.json()
    except ValueError:
        body = {}
    kind, q = body.get("kind", "day"), str(body.get("q") or "")[:500].strip()
    if kind not in ("day", "week", "ask"):
        raise web.HTTPBadRequest(text="kind must be day, week or ask")
    if kind == "ask" and not q:
        raise web.HTTPBadRequest(text="q is required for kind=ask")
    snap = advice_snapshot()
    if snap is None:
        return web.json_response({"error": "Set your height and take a weight reading first."}, status=422)
    try:
        r = await advisor.report(kind, snap, q or None)
    except LLMError as e:
        return web.json_response({"error": str(e)}, status=503)
    aid = advisor.save_advice(db, kind, r, question=q or None, source="dashboard")
    publish({"type": "advice"})
    return web.json_response({"id": aid, **r})


async def get_settings(request):
    local_only(request)
    return web.json_response(settings_view(request))


async def set_telegram(request):
    local_only(request)
    b, bot = await request.json(), request.app["bot"]
    old, c = telegram_cfg(), dict(kv_get("telegram", {}))
    try:
        if "allowed_ids" in b:
            c["allowed_ids"] = parse_ids(b["allowed_ids"])
        if "session_minutes" in b:
            m = int(b["session_minutes"])
            if not 1 <= m <= 180:
                raise ValueError("session window must be 1-180 minutes")
            c["session_minutes"] = m
    except (ValueError, TypeError) as e:
        return web.json_response({"error": f"invalid value: {e}"}, status=400)
    for k in ("enabled", "auto_save", "daily_summary"):
        if k in b:
            c[k] = bool(b[k])
    if "summary_time" in b:
        if not TIME_RE.match(str(b["summary_time"])):
            return web.json_response({"error": "summary time must look like 21:00"}, status=400)
        c["summary_time"] = str(b["summary_time"])
    tok = str(b.get("token") or "").strip()
    if tok:
        if not TOKEN_RE.match(tok):
            return web.json_response({"error": "that doesn't look like a bot token (123456:ABC…)"}, status=400)
        c["token"] = tok
    elif b.get("clear_token"):
        c["token"] = ""
    kv_set("telegram", c)
    new = telegram_cfg()
    if (old["token"], old["enabled"]) != (new["token"], new["enabled"]) or bot.state in ("stopped", "error"):
        await bot.apply()
    return web.json_response(settings_view(request))


async def set_ai(request):
    local_only(request)
    b = await request.json()
    url, model = str(b.get("base_url") or "").strip(), str(b.get("model") or "").strip()[:100]
    if url and not re.match(r"^https?://[^\s]+$", url):
        return web.json_response({"error": "base URL must start with http:// or https://"}, status=400)
    if url or model:
        kv_set("ai", {"base_url": url, "model": model})
    else:
        db.execute("DELETE FROM kv WHERE k='ai'")
        db.commit()
    config.set_llm_overrides(kv_get("ai", {}))
    return web.json_response(settings_view(request))


async def test_ai(request):
    local_only(request)
    s = config.llm_settings()
    try:
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=6)) as http:
            async with http.get(s["base_url"] + "/models", headers={"Authorization": f"Bearer {s['api_key']}"}) as r:
                data = await r.json(content_type=None)
                if r.status >= 400:
                    return web.json_response({"ok": False, "error": f"server answered {r.status}"})
    except Exception as e:
        return web.json_response({"ok": False, "error": f"cannot reach {s['base_url']}: {e}"})
    models = data.get("data", []) if isinstance(data, dict) else []
    entry = next((m for m in models if m.get("id") == s["model"]), None)
    mods = ((entry or {}).get("architecture") or {}).get("input_modalities")
    return web.json_response({"ok": True, "models": [m.get("id") for m in models], "model_found": entry is not None,
                              "vision": None if mods is None else "image" in mods})


async def test_telegram(request):
    local_only(request)
    bot = request.app["bot"]
    if bot.state != "running":
        return web.json_response({"error": "The bot is not running."}, status=409)
    return web.json_response({"sent": await bot.send_test()})


async def food_status(request):
    local_only(request)
    status = (await request.json()).get("status")
    mid = int(request.match_info["id"])
    meal = db.execute("SELECT ts FROM meals WHERE id=?", (mid,)).fetchone()
    try:
        ok = food.set_status(db, mid, status)
    except ValueError:
        raise web.HTTPBadRequest(text="status must be pending, confirmed or discarded")
    if not ok:
        raise web.HTTPNotFound()
    if status == "discarded" and meal:
        advisor.purge_for_meal(db, mid, meal["ts"])  # day advice written before the delete counted this meal
    publish({"type": "advice"})  # every open dashboard reloads, so daily kcal/macro totals are recomputed
    return web.json_response({"ok": True})


DAILY_REVALIDATE_AT = "22:00"


async def daily_revalidate_task():
    """Every day at 22:00: validate today's daily advice against the current meals. Advice whose totals no
    longer match is deleted; if none is left a new one is written, otherwise it is kept as is. Retries a
    failed model call every 10 minutes until midnight."""
    last_try = 0.0
    while True:
        try:
            await asyncio.sleep(60)
            now = datetime.now()
            key = now.strftime("%Y-%m-%d")
            if now.strftime("%H:%M") < DAILY_REVALIDATE_AT or kv_get("advice_revalidated") == key:
                continue
            if time.time() - last_try < 600:
                continue
            last_try = time.time()
            start = food.day_start(now.timestamp())
            if not food.meals_between(db, start, start + 86400):
                kv_set("advice_revalidated", key)       # nothing logged: nothing to advise on
                continue
            advisor.feed(db)                            # deletes daily advice that no longer matches
            if db.execute("SELECT 1 FROM advice WHERE kind='day' AND day=?", (key,)).fetchone():
                kv_set("advice_revalidated", key)       # calculation matches: leave it as is
                continue
            snap = advice_snapshot()
            if snap is None:
                continue
            r = await advisor.report("day", snap, None)
            advisor.save_advice(db, "day", r, source="scheduled")
            kv_set("advice_revalidated", key)
            publish({"type": "advice"})
        except asyncio.CancelledError:
            raise
        except LLMError as e:
            print(f"daily advice revalidation failed, will retry: {e}", flush=True)
        except Exception as e:
            print(f"daily advice revalidation error: {e}", flush=True)


async def on_start(app):
    await app["bot"].apply()
    app["revalidate"] = asyncio.create_task(daily_revalidate_task())
    if not app["no_ble"]:
        app["ble"] = asyncio.create_task(ble_task())
    else:
        live["ble"] = "disabled"


async def on_stop(app):
    app["revalidate"].cancel()
    await app["bot"].stop()


def make_app(lan, no_ble):
    app = web.Application()
    app["lan"], app["no_ble"] = lan, no_ble
    config.set_llm_overrides(kv_get("ai", {}))
    app["bot"] = tgbot.TelegramBot(db, cfg=telegram_cfg, target_kcal=target_kcal, latest_weight=latest_weight,
                                   kv_get=kv_get, kv_set=kv_set, plan=nutrition_plan,
                                   context=advice_snapshot, notify=lambda: publish({"type": "advice"}))
    async def manifest(request):
        return web.FileResponse(STATIC_DIR / "manifest.webmanifest",
                                headers={"Content-Type": "application/manifest+json"})

    async def favicon(request):
        return web.FileResponse(STATIC_DIR / "favicon.ico", headers={"Content-Type": "image/x-icon"})

    app.add_routes([
        web.static("/assets", STATIC_DIR / "assets"),
        web.get("/manifest.webmanifest", manifest),
        web.get("/favicon.ico", favicon),
        web.get("/", index), web.get("/api/state", state), web.get("/api/events", events),
        web.post("/api/profile", set_profile), web.post("/api/readings", post_reading),
        web.post("/api/import", import_readings),
        web.post("/api/food/analyze", food_analyze), web.post("/api/food/{id}/status", food_status),
        web.get("/api/food/{id}/photo/{idx}", food_photo),
        web.post("/api/advice", post_advice), web.get("/api/settings", get_settings), web.post("/api/settings/telegram", set_telegram),
        web.post("/api/settings/telegram/test", test_telegram),
        web.post("/api/settings/ai", set_ai), web.post("/api/settings/ai/test", test_ai),
        web.delete("/api/readings/{id}", del_reading), web.get("/api/export.csv", export_csv),
        web.get("/api/health/pending", health_pending), web.post("/api/health/ack", health_ack),
    ])
    app.on_startup.append(on_start)
    app.on_cleanup.append(on_stop)
    return app


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lan", action="store_true", help="listen on all interfaces")
    ap.add_argument("--no-ble", action="store_true")
    ap.add_argument("--port", type=int, default=8765)
    a = ap.parse_args()
    print(f"Dashboard: http://localhost:{a.port}   Health token: {token()}")
    web.run_app(make_app(a.lan, a.no_ble), host="0.0.0.0" if a.lan else "127.0.0.1",
                port=a.port, print=None)


if __name__ == "__main__":
    main()
