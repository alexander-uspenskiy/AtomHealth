"""Two-way sync core shared by the relay agent and the /api/sync/v1 endpoints.

Local changes to readings and confirmed meals are captured by SQLite triggers into `sync_outbox`
(so every code path - dashboard, Telegram bot, importer - is covered without touching it).
Outbound envelopes are built from the *current* row at send time. Inbound envelopes (from the
iPhone app) are merged with last-writer-wins on a per-entity version and de-duplicated against
existing readings. Applying inbound changes never re-queues them (the `applying` flag).

Envelope (plaintext, before the relay encrypts it):
    {"v": 1, "type": "weight|meal|activity_day|nutrition_day|workout", "op": "upsert|delete",
     "id": "<stable entity id>", "version": <int, ms-scale, strictly increasing per entity>,
     "updated_at": <unix seconds>, "data": {...}}
"""
import re
import time
from contextlib import contextmanager

ENVELOPE_VERSION = 1
OUTBOUND_TYPES = ("weight", "meal")
INBOUND_TYPES = ("weight", "activity_day", "nutrition_day", "workout")
DEDUPE_SECONDS = 120   # same weigh-in seen twice (e.g. scale app also wrote it to Health)
DEDUPE_KG = 0.1
_DAY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

SCHEMA = """
CREATE TABLE IF NOT EXISTS sync_outbox(
  seq INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT NOT NULL, sync_id TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS sync_flags(k TEXT PRIMARY KEY, v INTEGER NOT NULL);
INSERT OR IGNORE INTO sync_flags VALUES('applying', 0);
-- last version seen/sent per entity; live=1 means the other side currently holds an upsert for it
CREATE TABLE IF NOT EXISTS sync_versions(
  type TEXT NOT NULL, sync_id TEXT NOT NULL, version INTEGER NOT NULL, live INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(type, sync_id));
-- inbound entity that was merged into an existing local row instead of creating a new one
CREATE TABLE IF NOT EXISTS sync_links(
  type TEXT NOT NULL, sync_id TEXT NOT NULL, local_id INTEGER NOT NULL, PRIMARY KEY(type, sync_id));
CREATE TABLE IF NOT EXISTS sync_log(
  id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, direction TEXT NOT NULL,
  type TEXT, count INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL, detail TEXT);
CREATE TABLE IF NOT EXISTS activity_days(
  day TEXT PRIMARY KEY, active_kcal REAL, basal_kcal REAL, steps INTEGER, updated_at INTEGER NOT NULL);
-- nutrition logged by OTHER apps in Apple Health, aggregated per day by the phone.
-- Kept apart from `meals` so it can never double-count with Telegram/photo meals.
CREATE TABLE IF NOT EXISTS nutrition_days(
  day TEXT PRIMARY KEY, kcal REAL, protein_g REAL, carbs_g REAL, fat_g REAL, fiber_g REAL, updated_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS workouts(
  sync_id TEXT PRIMARY KEY, start_ts INTEGER NOT NULL, end_ts INTEGER, type TEXT, kcal REAL, distance_m REAL,
  updated_at INTEGER NOT NULL);
"""

_NOT_APPLYING = "(SELECT v FROM sync_flags WHERE k='applying')=0"

TRIGGERS = [
    # readings ---------------------------------------------------------------------------------
    f"""CREATE TRIGGER readings_sync_ai AFTER INSERT ON readings BEGIN
      UPDATE readings SET sync_id=lower(hex(randomblob(16))) WHERE id=NEW.id AND sync_id IS NULL;
      INSERT INTO sync_outbox(type,sync_id) SELECT 'weight', sync_id FROM readings
        WHERE id=NEW.id AND sync_id IS NOT NULL AND {_NOT_APPLYING};
    END""",
    f"""CREATE TRIGGER readings_sync_au AFTER UPDATE OF ts, weight, impedance ON readings
      WHEN NEW.sync_id IS NOT NULL AND {_NOT_APPLYING} BEGIN
      INSERT INTO sync_outbox(type,sync_id) VALUES('weight', NEW.sync_id);
    END""",
    f"""CREATE TRIGGER readings_sync_ad AFTER DELETE ON readings
      WHEN OLD.sync_id IS NOT NULL AND {_NOT_APPLYING} BEGIN
      INSERT INTO sync_outbox(type,sync_id) VALUES('weight', OLD.sync_id);
    END""",
    # meals ------------------------------------------------------------------------------------
    f"""CREATE TRIGGER meals_sync_ai AFTER INSERT ON meals BEGIN
      UPDATE meals SET sync_id=lower(hex(randomblob(16))) WHERE id=NEW.id AND sync_id IS NULL;
      INSERT INTO sync_outbox(type,sync_id) SELECT 'meal', sync_id FROM meals
        WHERE id=NEW.id AND sync_id IS NOT NULL AND {_NOT_APPLYING};
    END""",
    f"""CREATE TRIGGER meals_sync_au
      AFTER UPDATE OF ts, caption, meal_type, kcal, protein_g, carbs_g, fat_g, fiber_g, status ON meals
      WHEN NEW.sync_id IS NOT NULL AND {_NOT_APPLYING} BEGIN
      INSERT INTO sync_outbox(type,sync_id) VALUES('meal', NEW.sync_id);
    END""",
    f"""CREATE TRIGGER meals_sync_ad AFTER DELETE ON meals
      WHEN OLD.sync_id IS NOT NULL AND {_NOT_APPLYING} BEGIN
      INSERT INTO sync_outbox(type,sync_id) VALUES('meal', OLD.sync_id);
    END""",
    # meal items mark their parent meal dirty ---------------------------------------------------
    f"""CREATE TRIGGER meal_items_sync_ai AFTER INSERT ON meal_items WHEN {_NOT_APPLYING} BEGIN
      INSERT INTO sync_outbox(type,sync_id) SELECT 'meal', sync_id FROM meals
        WHERE id=NEW.meal_id AND sync_id IS NOT NULL;
    END""",
    f"""CREATE TRIGGER meal_items_sync_au AFTER UPDATE ON meal_items WHEN {_NOT_APPLYING} BEGIN
      INSERT INTO sync_outbox(type,sync_id) SELECT 'meal', sync_id FROM meals
        WHERE id=NEW.meal_id AND sync_id IS NOT NULL;
    END""",
    f"""CREATE TRIGGER meal_items_sync_ad AFTER DELETE ON meal_items WHEN {_NOT_APPLYING} BEGIN
      INSERT INTO sync_outbox(type,sync_id) SELECT 'meal', sync_id FROM meals
        WHERE id=OLD.meal_id AND sync_id IS NOT NULL;
    END""",
]


def _cols(db, table):
    return {r[1] for r in db.execute(f"PRAGMA table_info({table})")}


def migrate(db):
    """Idempotent. Adds sync columns/tables/triggers; queues existing data once for the first sync."""
    db.executescript(SCHEMA)
    for table, col, decl in (("readings", "sync_id", "TEXT"), ("readings", "fat_pct_m", "REAL"),
                             ("readings", "lean_kg_m", "REAL"), ("meals", "sync_id", "TEXT")):
        if col not in _cols(db, table):
            db.execute(f"ALTER TABLE {table} ADD COLUMN {col} {decl}")
    for table in ("readings", "meals"):  # backfill BEFORE triggers exist so it does not queue noise
        db.execute(f"UPDATE {table} SET sync_id=lower(hex(randomblob(16))) WHERE sync_id IS NULL")
    db.executescript("CREATE UNIQUE INDEX IF NOT EXISTS readings_sync_id ON readings(sync_id);"
                     "CREATE UNIQUE INDEX IF NOT EXISTS meals_sync_id ON meals(sync_id);")
    for t in db.execute("SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE '%\\_sync\\_%' ESCAPE '\\'").fetchall():
        db.execute(f"DROP TRIGGER {t[0]}")
    for sql in TRIGGERS:
        db.execute(sql)
    if not db.execute("SELECT 1 FROM kv WHERE k='sync_backfilled'").fetchone():
        db.execute("INSERT INTO sync_outbox(type,sync_id) SELECT 'weight', sync_id FROM readings WHERE source!='applehealth'")
        db.execute("INSERT INTO sync_outbox(type,sync_id) SELECT 'meal', sync_id FROM meals WHERE status='confirmed'")
        db.execute("INSERT INTO kv VALUES('sync_backfilled','1')")
    db.commit()


@contextmanager
def applying(db):
    """Writes inside this block are remote changes: the triggers must not queue them for sending."""
    db.execute("UPDATE sync_flags SET v=1 WHERE k='applying'")
    try:
        yield
        db.commit()
    except BaseException:
        db.rollback()
        raise
    finally:
        db.execute("UPDATE sync_flags SET v=0 WHERE k='applying'")
        db.commit()


def log(db, direction, type_, count, status, detail=None):
    db.execute("INSERT INTO sync_log(ts,direction,type,count,status,detail) VALUES(?,?,?,?,?,?)",
               (int(time.time()), direction, type_, count, status, (detail or "")[:300] or None))
    db.execute("DELETE FROM sync_log WHERE id <= (SELECT MAX(id) FROM sync_log) - 500")
    db.commit()


# ---------------------------------------------------------------------------- outbound
def outbox_max(db):
    return db.execute("SELECT COALESCE(MAX(seq),0) FROM sync_outbox").fetchone()[0]


def _next_version(db, type_, sync_id):
    row = db.execute("SELECT version FROM sync_versions WHERE type=? AND sync_id=?", (type_, sync_id)).fetchone()
    return max(int(time.time() * 1000), (row[0] + 1) if row else 0)


def _is_live(db, type_, sync_id):
    row = db.execute("SELECT live FROM sync_versions WHERE type=? AND sync_id=?", (type_, sync_id)).fetchone()
    return bool(row and row[0])


def _snapshot(db, type_, sync_id):
    """Current state of an entity as an envelope body, or None if it should not exist on the other side."""
    if type_ == "weight":
        r = db.execute("SELECT * FROM readings WHERE sync_id=? AND source!='applehealth'", (sync_id,)).fetchone()
        if not r:
            return None
        return {"ts": r["ts"], "weight_kg": r["weight"], "impedance": r["impedance"], "source": r["source"]}
    if type_ == "meal":
        m = db.execute("SELECT * FROM meals WHERE sync_id=? AND status='confirmed'", (sync_id,)).fetchone()
        if not m:  # pending/discarded/deleted meals never live in Health
            return None
        items = [{"name": i["name"], "grams": i["grams"], "kcal": i["kcal"], "protein_g": i["protein_g"],
                  "carbs_g": i["carbs_g"], "fat_g": i["fat_g"]}
                 for i in db.execute("SELECT * FROM meal_items WHERE meal_id=? ORDER BY id", (m["id"],))]
        return {"ts": m["ts"], "caption": m["caption"], "meal_type": m["meal_type"], "kcal": m["kcal"],
                "protein_g": m["protein_g"], "carbs_g": m["carbs_g"], "fat_g": m["fat_g"],
                "fiber_g": m["fiber_g"], "items": items}
    return None


def collect(db, after_seq, limit=200, only_if_live=True):
    """Envelopes for every entity touched after `after_seq` (coalesced). Returns (envelopes, next_seq).

    A delete is emitted only if the other side was previously sent an upsert (`only_if_live`), which keeps
    never-sent pending meals from generating noise. Nothing is persisted here: call `mark_sent` after the
    envelopes were actually delivered, so a failed delivery is retried with nothing lost.
    """
    rows = db.execute("SELECT type, sync_id, MAX(seq) AS m FROM sync_outbox WHERE seq>? "
                      "GROUP BY type, sync_id ORDER BY m LIMIT ?", (after_seq, limit)).fetchall()
    out = []
    for r in rows:
        body = _snapshot(db, r["type"], r["sync_id"])
        if body is None and only_if_live and not _is_live(db, r["type"], r["sync_id"]):
            continue
        out.append({"v": ENVELOPE_VERSION, "type": r["type"], "op": "upsert" if body is not None else "delete",
                    "id": r["sync_id"], "version": _next_version(db, r["type"], r["sync_id"]),
                    "updated_at": int(time.time()), "data": body})
    next_seq = rows[-1]["m"] if len(rows) == limit else max(outbox_max(db), after_seq)
    return out, next_seq


def mark_sent(db, envelopes):
    for e in envelopes:
        db.execute("INSERT INTO sync_versions(type,sync_id,version,live) VALUES(?,?,?,?) "
                   "ON CONFLICT(type,sync_id) DO UPDATE SET version=excluded.version, live=excluded.live",
                   (e["type"], e["id"], e["version"], 1 if e["op"] == "upsert" else 0))
    db.commit()


def prune_outbox(db, upto_seq):
    db.execute("DELETE FROM sync_outbox WHERE seq<=?", (upto_seq,))
    db.commit()


# ---------------------------------------------------------------------------- inbound
class Invalid(ValueError):
    pass


def _num(v, lo, hi, name, required=True):
    if v is None and not required:
        return None
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not (lo <= v <= hi):
        raise Invalid(f"{name} out of range")
    return float(v)


def _day(v):
    if not isinstance(v, str) or not _DAY_RE.match(v):
        raise Invalid("bad day")
    return v


def validate(env):
    if not isinstance(env, dict) or env.get("v") != ENVELOPE_VERSION:
        raise Invalid("unsupported envelope")
    if env.get("type") not in INBOUND_TYPES:
        raise Invalid("unsupported type")
    if env.get("op") not in ("upsert", "delete"):
        raise Invalid("bad op")
    if not isinstance(env.get("id"), str) or not (1 <= len(env["id"]) <= 128):
        raise Invalid("bad id")
    if isinstance(env.get("version"), bool) or not isinstance(env.get("version"), int) or env["version"] < 0:
        raise Invalid("bad version")
    if env["op"] == "upsert" and not isinstance(env.get("data"), dict):
        raise Invalid("missing data")


def apply_envelope(db, env):
    """Merge one inbound envelope. Returns 'applied', 'stale', 'merged' or raises Invalid.

    Caller wraps batches in `with applying(db):` so triggers stay quiet and the batch is atomic.
    """
    validate(env)
    type_, sid, version, op = env["type"], env["id"], env["version"], env["op"]
    seen = db.execute("SELECT version FROM sync_versions WHERE type=? AND sync_id=?", (type_, sid)).fetchone()
    if seen and seen[0] >= version:
        return "stale"
    now = int(time.time())
    result = "applied"
    if op == "upsert":
        d = env["data"]
        if type_ == "weight":
            result = _upsert_weight(db, sid, d)
        elif type_ == "activity_day":
            day = _day(d.get("day"))
            db.execute("INSERT INTO activity_days(day,active_kcal,basal_kcal,steps,updated_at) VALUES(?,?,?,?,?) "
                       "ON CONFLICT(day) DO UPDATE SET active_kcal=excluded.active_kcal, basal_kcal=excluded.basal_kcal,"
                       " steps=excluded.steps, updated_at=excluded.updated_at",
                       (day, _num(d.get("active_kcal"), 0, 20000, "active_kcal", False),
                        _num(d.get("basal_kcal"), 0, 20000, "basal_kcal", False),
                        None if d.get("steps") is None else int(_num(d["steps"], 0, 300000, "steps")), now))
        elif type_ == "nutrition_day":
            day = _day(d.get("day"))
            db.execute("INSERT INTO nutrition_days(day,kcal,protein_g,carbs_g,fat_g,fiber_g,updated_at) VALUES(?,?,?,?,?,?,?) "
                       "ON CONFLICT(day) DO UPDATE SET kcal=excluded.kcal, protein_g=excluded.protein_g,"
                       " carbs_g=excluded.carbs_g, fat_g=excluded.fat_g, fiber_g=excluded.fiber_g, updated_at=excluded.updated_at",
                       (day,) + tuple(_num(d.get(k), 0, 50000, k, False) for k in ("kcal", "protein_g", "carbs_g", "fat_g", "fiber_g")) + (now,))
        elif type_ == "workout":
            start = int(_num(d.get("start_ts"), 946684800, now + 86400, "start_ts"))
            end = d.get("end_ts")
            end = None if end is None else int(_num(end, start, start + 86400, "end_ts"))
            wtype = d.get("type")
            db.execute("INSERT INTO workouts(sync_id,start_ts,end_ts,type,kcal,distance_m,updated_at) VALUES(?,?,?,?,?,?,?) "
                       "ON CONFLICT(sync_id) DO UPDATE SET start_ts=excluded.start_ts, end_ts=excluded.end_ts, type=excluded.type,"
                       " kcal=excluded.kcal, distance_m=excluded.distance_m, updated_at=excluded.updated_at",
                       (sid, start, end, wtype[:40] if isinstance(wtype, str) else None,
                        _num(d.get("kcal"), 0, 20000, "kcal", False), _num(d.get("distance_m"), 0, 1_000_000, "distance_m", False), now))
    else:
        if type_ == "weight":
            if db.execute("DELETE FROM sync_links WHERE type='weight' AND sync_id=?", (sid,)).rowcount == 0:
                db.execute("DELETE FROM readings WHERE sync_id=? AND source='applehealth'", (sid,))
        elif type_ in ("activity_day", "nutrition_day"):
            table = "activity_days" if type_ == "activity_day" else "nutrition_days"
            if sid.startswith("day:") and _DAY_RE.match(sid[4:]):
                db.execute(f"DELETE FROM {table} WHERE day=?", (sid[4:],))
        elif type_ == "workout":
            db.execute("DELETE FROM workouts WHERE sync_id=?", (sid,))
    db.execute("INSERT INTO sync_versions(type,sync_id,version,live) VALUES(?,?,?,?) "
               "ON CONFLICT(type,sync_id) DO UPDATE SET version=excluded.version, live=excluded.live",
               (type_, sid, version, 1 if op == "upsert" else 0))
    return result


def _upsert_weight(db, sid, d):
    ts = int(_num(d.get("ts"), 946684800, time.time() + 86400, "ts"))
    w = round(_num(d.get("weight_kg"), 20, 300, "weight_kg"), 2)
    fat = _num(d.get("fat_pct"), 2, 75, "fat_pct", False)
    lean = _num(d.get("lean_kg"), 10, 200, "lean_kg", False)
    link = db.execute("SELECT local_id FROM sync_links WHERE type='weight' AND sync_id=?", (sid,)).fetchone()
    own = db.execute("SELECT id FROM readings WHERE sync_id=? AND source='applehealth'", (sid,)).fetchone()
    if own:
        db.execute("UPDATE readings SET ts=?, weight=?, fat_pct_m=?, lean_kg_m=? WHERE id=?", (ts, w, fat, lean, own[0]))
        return "applied"
    if link:  # merged into a scale/manual reading: only add the measured body composition
        db.execute("UPDATE readings SET fat_pct_m=COALESCE(?,fat_pct_m), lean_kg_m=COALESCE(?,lean_kg_m) WHERE id=?",
                   (fat, lean, link[0]))
        return "merged"
    dup = db.execute("SELECT id FROM readings WHERE source!='applehealth' AND ABS(ts-?)<=? AND ABS(weight-?)<=? "
                     "ORDER BY ABS(ts-?) LIMIT 1", (ts, DEDUPE_SECONDS, w, DEDUPE_KG, ts)).fetchone()
    if dup:
        db.execute("INSERT INTO sync_links(type,sync_id,local_id) VALUES('weight',?,?)", (sid, dup[0]))
        db.execute("UPDATE readings SET fat_pct_m=COALESCE(?,fat_pct_m), lean_kg_m=COALESCE(?,lean_kg_m) WHERE id=?",
                   (fat, lean, dup[0]))
        return "merged"
    db.execute("INSERT INTO readings(ts,weight,source,synced,sync_id,fat_pct_m,lean_kg_m) VALUES(?,?,'applehealth',1,?,?,?)",
               (ts, w, sid, fat, lean))
    return "applied"


def apply_batch(db, envelopes):
    """Apply many inbound envelopes atomically-per-envelope. Returns {'applied':n,'merged':n,'stale':n,'invalid':n}."""
    counts = {"applied": 0, "merged": 0, "stale": 0, "invalid": 0}
    for env in envelopes:
        try:
            with applying(db):
                counts[apply_envelope(db, env)] += 1
        except Invalid:
            counts["invalid"] += 1
    return counts


def status(db):
    q = lambda sql: db.execute(sql).fetchone()[0]
    return {
        "outbox_total": q("SELECT COUNT(*) FROM sync_outbox"), "outbox_max_seq": outbox_max(db),
        "activity_days": q("SELECT COUNT(*) FROM activity_days"), "nutrition_days": q("SELECT COUNT(*) FROM nutrition_days"),
        "workouts": q("SELECT COUNT(*) FROM workouts"),
        "applehealth_readings": q("SELECT COUNT(*) FROM readings WHERE source='applehealth'"),
        "merged_readings": q("SELECT COUNT(*) FROM sync_links"),
        "recent": [dict(r) for r in db.execute("SELECT ts,direction,type,count,status,detail FROM sync_log ORDER BY id DESC LIMIT 20")],
    }
