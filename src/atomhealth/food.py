"""Meal analysis: photo (and/or text) -> validated calories and macros via the local vision LLM.

CLI (no storage):  .venv/bin/python -m atomhealth.food photo1.jpg [photo2.jpg ...] [-- caption]
"""
import asyncio
import io
import json
import sys
import time
from pathlib import Path

from PIL import Image, ImageOps

from .llm import LLM, extract_json, image_part

MAX_SIDE = 1280  # Telegram already caps photos at 1280 px, so these are not downscaled again
JPEG_QUALITY = 88
MAX_PHOTOS = 6
MEAL_TYPES = ("breakfast", "lunch", "dinner", "snack", "unknown")
# Meal type follows the clock (server local time), never the food: a salad at 8 pm is dinner.
MEAL_HOURS = ((4, "breakfast"), (11, "lunch"), (16, "snack"), (18, "dinner"), (23, "snack"))
MAX_GRAMS, MAX_ITEM_KCAL = 2000.0, 3000.0

SYSTEM = """You are a careful nutrition analyst. You look at a photo of a meal (and an optional \
caption from the user) and estimate what was eaten. Reply with ONE JSON object and nothing else.

Schema:
{"is_food": true|false,
 "items": [{"name": str, "grams": number, "kcal": number, "protein_g": number,
            "carbs_g": number, "fat_g": number, "fiber_g": number}],
 "confidence": number between 0 and 1,
 "notes": str}

Rules:
- One item per distinct food or drink. Name items specifically ("grilled chicken breast", not "meat").
- grams = edible weight as served (cooked weight for cooked food). Judge portion size from the plate, \
cutlery, hands or packaging; a standard dinner plate is about 26 cm across.
- Include visible cooking fat, dressings, sauces and sugary drinks.
- If the caption gives quantities or says how it was made, trust it over your visual guess.
- kcal must be consistent with the macros: kcal = 4*protein + 4*carbs + 9*fat.
- confidence reflects how sure you are about identification AND portion size; lower it for mixed dishes, \
hidden ingredients or unclear scale. Mention the main uncertainty in notes (one short sentence).
- You may get several photos of the SAME eating session (other angles, extra courses, a drink or dessert \
added later). Treat them as one meal: identify each food once and never count the same food twice.
- If the image shows no food or drink, return {"is_food": false, "items": [], "confidence": 0, "notes": "..."}.
"""


def meal_type_for(ts=None) -> str:
    """breakfast 04-11, lunch 11-16, snack 16-18, dinner 18-23, late snack 23-04."""
    hour = time.localtime(ts or time.time()).tm_hour
    name = "snack"                      # 00:00-03:59 is the tail of the late-night snack window
    for start, label in MEAL_HOURS:
        if hour >= start:
            name = label
    return name


class AnalysisError(Exception):
    pass


def prepare_image(data: bytes) -> bytes:
    """Normalise a photo once: EXIF rotation, RGB, at most MAX_SIDE px, JPEG. Already-prepared JPEGs are
    returned untouched, so re-analysing a stored meal never re-encodes it (no generation loss)."""
    try:
        img = Image.open(io.BytesIO(data))
        if (img.format == "JPEG" and img.mode == "RGB" and max(img.size) <= MAX_SIDE
                and img.getexif().get(0x0112, 1) == 1):
            return data
        img = ImageOps.exif_transpose(img)
    except Exception as e:  # PIL raises many types for bad input
        raise AnalysisError(f"not a readable image: {e}") from e
    if img.mode != "RGB":
        img = img.convert("RGB")
    img.thumbnail((MAX_SIDE, MAX_SIDE))
    out = io.BytesIO()
    img.save(out, "JPEG", quality=JPEG_QUALITY)
    return out.getvalue()


def _num(v, default=0.0):
    try:
        f = float(v)
    except (TypeError, ValueError):
        return default
    return f if f == f and f not in (float("inf"), float("-inf")) else default  # reject NaN/inf


def _macro_kcal(p, c, f):
    return 4 * p + 4 * c + 9 * f


def validate(raw) -> dict:
    """Normalise model output; recompute inconsistent calories; sum totals. Raises AnalysisError."""
    if not isinstance(raw, dict):
        raise AnalysisError("analysis is not a JSON object")
    if raw.get("is_food") is False:
        return {"is_food": False, "meal_type": "unknown", "items": [], "totals": _totals([]),
                "confidence": 0.0, "notes": str(raw.get("notes") or "No food detected.")[:300],
                "adjusted": []}
    items, adjusted = [], []
    for it in raw.get("items") or []:
        if not isinstance(it, dict) or not str(it.get("name", "")).strip():
            continue
        name = str(it["name"]).strip()[:80]
        grams = min(max(_num(it.get("grams")), 0.0), MAX_GRAMS)
        p, c, f = (max(_num(it.get(k)), 0.0) for k in ("protein_g", "carbs_g", "fat_g"))
        fiber = max(_num(it.get("fiber_g")), 0.0)
        kcal = max(_num(it.get("kcal")), 0.0)
        derived = _macro_kcal(p, c, f)
        if derived > 0 and (kcal == 0 or abs(kcal - derived) / derived > 0.25):
            if kcal:
                adjusted.append(f"{name}: kcal {kcal:.0f} -> {derived:.0f} (from macros)")
            kcal = derived
        elif derived == 0 and kcal > 0:
            adjusted.append(f"{name}: kcal given without macros")
        if kcal > MAX_ITEM_KCAL:
            raise AnalysisError(f"implausible calories for {name}: {kcal:.0f}")
        items.append({"name": name, "grams": round(grams), "kcal": round(kcal),
                      "protein_g": round(p, 1), "carbs_g": round(c, 1), "fat_g": round(f, 1),
                      "fiber_g": round(fiber, 1)})
    if not items:
        raise AnalysisError("no food items identified")
    mt = str(raw.get("meal_type") or "unknown").lower()
    return {"is_food": True, "meal_type": mt if mt in MEAL_TYPES else "unknown", "items": items,
            "totals": _totals(items), "confidence": min(max(_num(raw.get("confidence"), 0.5), 0.0), 1.0),
            "notes": str(raw.get("notes") or "")[:300], "adjusted": adjusted}


def _totals(items):
    return {k: round(sum(i[k] for i in items), 1 if k != "kcal" else 0)
            for k in ("kcal", "protein_g", "carbs_g", "fat_g", "fiber_g")}


async def analyze_meal(images=None, caption: str = "", llm: LLM | None = None) -> dict:
    """Analyse one meal from photo(s) and/or a caption. `images` is bytes, a list of bytes, or None.
    Several photos are treated as one eating session. Returns a validated analysis dict."""
    if isinstance(images, (bytes, bytearray)):
        images = [bytes(images)]
    images = [i for i in (images or []) if i]
    caption = (caption or "").strip()
    if not images and not caption:
        raise AnalysisError("need a photo or a description")
    if len(images) > MAX_PHOTOS:
        raise AnalysisError(f"at most {MAX_PHOTOS} photos per meal")
    llm = llm or LLM()
    if not images:
        prompt = "Analyse this meal from the description only."
    elif len(images) == 1:
        prompt = "Analyse this meal."
    else:
        prompt = f"Analyse this meal. The {len(images)} photos below show the same eating session."
    if caption:
        prompt += f"\nUser caption: {caption}"
    content = [{"type": "text", "text": prompt}] + [image_part(prepare_image(i)) for i in images]
    msgs = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": content}]
    last = None
    for _ in range(2):  # one retry if the model returns malformed or implausible data
        raw = extract_json(await llm.chat(msgs, max_tokens=1500, temperature=0.2))
        try:
            return validate(raw)
        except AnalysisError as e:
            last = e
    raise last


# ---------- storage (db passed in so this module does not import the app) ----------
def _save_photos(db, meal_id, photos, start_idx=0):
    """Store photos as (already reduced) JPEG blobs inside the database."""
    for n, data in enumerate(photos, start=start_idx):
        db.execute("INSERT INTO meal_photos(meal_id, idx, mime, data) VALUES(?,?,?,?)",
                   (meal_id, n, "image/jpeg", prepare_image(data)))


def _write_items(db, meal_id, analysis):
    db.execute("DELETE FROM meal_items WHERE meal_id=?", (meal_id,))
    db.executemany(
        "INSERT INTO meal_items(meal_id, name, grams, kcal, protein_g, carbs_g, fat_g) VALUES(?,?,?,?,?,?,?)",
        [(meal_id, i["name"], i["grams"], i["kcal"], i["protein_g"], i["carbs_g"], i["fat_g"])
         for i in analysis["items"]])


def store_meal(db, analysis: dict, *, photos: list[bytes] | None, caption: str,
               ts: int | None = None, source: str = "telegram") -> int:
    """Insert a pending meal with its items and photos. Returns meal id."""
    ts = int(ts or time.time())
    analysis["meal_type"] = meal_type_for(ts)
    t = analysis["totals"]
    cur = db.execute(
        "INSERT INTO meals(ts, caption, meal_type, kcal, protein_g, carbs_g, fat_g, fiber_g, confidence,"
        " status, source, raw_json) VALUES(?,?,?,?,?,?,?,?,?,'pending',?,?)",
        (ts, caption or None, analysis["meal_type"], t["kcal"], t["protein_g"], t["carbs_g"], t["fat_g"],
         t["fiber_g"], analysis["confidence"], source, json.dumps(analysis)))
    mid = cur.lastrowid
    _write_items(db, mid, analysis)
    _save_photos(db, mid, photos or [])
    db.commit()
    return mid


def meal_photo(db, meal_id: int, idx: int = 0):
    """(mime, bytes) of one stored photo, or None."""
    r = db.execute("SELECT mime, data FROM meal_photos WHERE meal_id=? AND idx=?", (meal_id, idx)).fetchone()
    return (r[0], bytes(r[1])) if r else None


def meal_photo_count(db, meal_id: int) -> int:
    return db.execute("SELECT COUNT(*) FROM meal_photos WHERE meal_id=?", (meal_id,)).fetchone()[0]


def meal_inputs(db, meal_id: int):
    """Stored photos and caption of a pending meal, or None if missing / no longer pending."""
    row = db.execute("SELECT caption, status FROM meals WHERE id=?", (meal_id,)).fetchone()
    if not row or row[1] != "pending":
        return None
    photos = [bytes(r[0]) for r in db.execute("SELECT data FROM meal_photos WHERE meal_id=? ORDER BY idx", (meal_id,))]
    return {"caption": row[0] or "", "photos": photos}


async def extend_meal(db, meal_id: int, new_photos: list[bytes], new_caption: str,
                      llm: LLM | None = None) -> dict:
    """Add photos/notes to a still-pending meal and re-analyse the whole session together."""
    prev = meal_inputs(db, meal_id)
    if prev is None:
        raise AnalysisError("meal not found or already confirmed")
    new_photos = [prepare_image(p) for p in new_photos]  # also validates them before any DB change
    caption = " ".join(c for c in (prev["caption"], (new_caption or "").strip()) if c)
    analysis = await analyze_meal(prev["photos"] + new_photos, caption, llm=llm)
    if not analysis["is_food"]:
        raise AnalysisError("the new photo does not show food")
    analysis["meal_type"] = meal_type_for(db.execute("SELECT ts FROM meals WHERE id=?", (meal_id,)).fetchone()[0])
    t = analysis["totals"]
    db.execute("UPDATE meals SET caption=?, meal_type=?, kcal=?, protein_g=?, carbs_g=?, fat_g=?, fiber_g=?,"
               " confidence=?, raw_json=? WHERE id=?",
               (caption or None, analysis["meal_type"], t["kcal"], t["protein_g"], t["carbs_g"], t["fat_g"],
                t["fiber_g"], analysis["confidence"], json.dumps(analysis), meal_id))
    _write_items(db, meal_id, analysis)
    _save_photos(db, meal_id, new_photos, start_idx=len(prev["photos"]))
    db.commit()
    return analysis


def day_start(ts=None) -> int:
    """Local midnight (server time zone) of the day containing ts."""
    t = time.localtime(ts or time.time())
    return int(time.mktime((t.tm_year, t.tm_mon, t.tm_mday, 0, 0, 0, 0, 0, -1)))


def meals_between(db, start: int, end: int, status: str = "confirmed"):
    return db.execute("SELECT * FROM meals WHERE ts>=? AND ts<? AND status=? ORDER BY ts", (start, end, status)).fetchall()


def sum_meals(rows) -> dict:
    return {k: round(sum((r[k] or 0) for r in rows), 1) for k in ("kcal", "protein_g", "carbs_g", "fat_g", "fiber_g")}


def last_meal(db, source: str | None = None):
    """Most recent meal that has not been discarded."""
    q, args = "SELECT * FROM meals WHERE status!='discarded'", ()
    if source:
        q, args = q + " AND source=?", (source,)
    return db.execute(q + " ORDER BY ts DESC, id DESC LIMIT 1", args).fetchone()


def set_status(db, meal_id: int, status: str) -> bool:
    if status not in ("pending", "confirmed", "discarded"):
        raise ValueError(status)
    cur = db.execute("UPDATE meals SET status=? WHERE id=?", (status, meal_id))
    db.commit()
    return cur.rowcount == 1


def delete_meal(db, meal_id: int) -> bool:
    """Permanently remove a meal with its items and photos (for things sent by mistake)."""
    db.execute("DELETE FROM meal_photos WHERE meal_id=?", (meal_id,))
    db.execute("DELETE FROM meal_items WHERE meal_id=?", (meal_id,))
    cur = db.execute("DELETE FROM meals WHERE id=?", (meal_id,))
    db.commit()
    return cur.rowcount == 1


def retag_meals(db) -> int:
    """Re-derive meal_type from the timestamp for meals stored when the model chose it."""
    n = 0
    for r in db.execute("SELECT id, ts, meal_type FROM meals").fetchall():
        t = meal_type_for(r[1])
        if r[2] != t:
            db.execute("UPDATE meals SET meal_type=? WHERE id=?", (t, r[0]))
            n += 1
    db.commit()
    return n


def _cli():
    """Usage: python -m atomhealth.food img1.jpg [img2.jpg ...] [-- caption words]"""
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    caption = ""
    if "--" in args:
        i = args.index("--")
        args, caption = args[:i], " ".join(args[i + 1:])
    images = []
    for a in args:
        p = Path(a)
        if p.suffix.lower() == ".txt":
            caption = (caption + " " + p.read_text()).strip()
        else:
            images.append(p.read_bytes())
    try:
        print(json.dumps(asyncio.run(analyze_meal(images, caption)), indent=2))
    except Exception as e:  # AnalysisError / LLMError: show a message, not a traceback
        sys.exit(f"error: {e}")


if __name__ == "__main__":
    _cli()
