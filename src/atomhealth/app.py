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
import secrets
import sqlite3
import time
from datetime import datetime
from pathlib import Path

from aiohttp import web

from . import bodycomp, config, food  # noqa: F401  (config loads .env)
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

DEFAULT_PROFILE = {
    "height_cm": 174, "age": 30, "birthdate": None, "sex": "male",
    "target_weight": None, "target_fat_pct": None, "target_date": None,
    "activity": 1.375, "diet_goal": "auto", "diet_pace": None, "diet_style": "balanced",
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
  id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, photo_path TEXT, caption TEXT,
  meal_type TEXT, kcal REAL, protein_g REAL, carbs_g REAL, fat_g REAL, fiber_g REAL,
  confidence REAL, status TEXT NOT NULL DEFAULT 'pending',  -- pending | confirmed | discarded
  source TEXT DEFAULT 'telegram', raw_json TEXT);
CREATE TABLE IF NOT EXISTS meal_items(
  id INTEGER PRIMARY KEY AUTOINCREMENT, meal_id INTEGER NOT NULL REFERENCES meals(id) ON DELETE CASCADE,
  name TEXT NOT NULL, grams REAL, kcal REAL, protein_g REAL, carbs_g REAL, fat_g REAL);
CREATE INDEX IF NOT EXISTS meals_ts ON meals(ts);
""")
db.execute("PRAGMA foreign_keys=ON")


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
    st = {"w": None, "since": 0.0, "armed": False}

    def cb(dev, adv):
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
            rid = add_reading(w, now, imp)
            live["last_saved"] = rid
            publish({"type": "saved", "id": rid, **live})

    while True:
        try:
            live["ble"] = "scanning"
            publish({"type": "live", **live})
            async with BleakScanner(cb):
                while True:
                    await asyncio.sleep(5)
                    if live["ts"] and time.time() - live["ts"] > 60 and live["weight"] is not None:
                        live.update(weight=None, stable=False)
                        publish({"type": "live", **live})
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
        "live": live, "health_token": token(),
    })


async def set_profile(request):
    local_only(request)
    body = await request.json()
    p = profile()
    for k in DEFAULT_PROFILE:
        if k in body:
            v = body[k]
            if k in ("height_cm", "age", "target_weight", "target_fat_pct", "activity", "diet_pace"):
                v = float(v) if v not in (None, "") else None
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


MEALS_DIR = DATA_DIR / "meals"
MAX_UPLOAD = 15 * 1024 * 1024


async def food_analyze(request):
    """POST multipart: photo (file, optional) + caption (text, optional). Stores a pending meal."""
    local_only(request)
    photo, caption = None, ""
    if request.content_type == "multipart/form-data":
        async for part in await request.multipart():
            if part.name == "photo":
                photo = bytes(await part.read(decode=False)) or None
                if photo and len(photo) > MAX_UPLOAD:
                    raise web.HTTPRequestEntityTooLarge(max_size=MAX_UPLOAD, actual_size=len(photo))
            elif part.name == "caption":
                caption = (await part.text())[:500]
    else:
        caption = str((await request.json()).get("caption", ""))[:500]
    try:
        analysis = await food.analyze_meal(photo, caption)
    except food.AnalysisError as e:
        return web.json_response({"error": str(e)}, status=422)
    except LLMError as e:
        return web.json_response({"error": str(e)}, status=503)
    if not analysis["is_food"]:
        return web.json_response({"meal_id": None, "analysis": analysis})
    mid = food.store_meal(db, analysis, photo=photo, caption=caption, photos_dir=MEALS_DIR, source="api")
    return web.json_response({"meal_id": mid, "analysis": analysis})


async def food_status(request):
    local_only(request)
    status = (await request.json()).get("status")
    try:
        ok = food.set_status(db, int(request.match_info["id"]), status)
    except ValueError:
        raise web.HTTPBadRequest(text="status must be pending, confirmed or discarded")
    if not ok:
        raise web.HTTPNotFound()
    return web.json_response({"ok": True})


async def on_start(app):
    if not app["no_ble"]:
        app["ble"] = asyncio.create_task(ble_task())
    else:
        live["ble"] = "disabled"


def make_app(lan, no_ble):
    app = web.Application()
    app["lan"], app["no_ble"] = lan, no_ble
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
        web.delete("/api/readings/{id}", del_reading), web.get("/api/export.csv", export_csv),
        web.get("/api/health/pending", health_pending), web.post("/api/health/ack", health_ack),
    ])
    app.on_startup.append(on_start)
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
