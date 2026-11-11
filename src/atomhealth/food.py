"""Meal analysis: photo (and/or text) -> validated calories and macros via the local vision LLM.

CLI (no storage):  .venv/bin/python -m atomhealth.food photo.jpg ["caption"]
"""
import asyncio
import io
import json
import sys
import time
from pathlib import Path

from PIL import Image, ImageOps

from .llm import LLM, extract_json, image_part

MAX_SIDE = 1024
MEAL_TYPES = ("breakfast", "lunch", "dinner", "snack", "unknown")
MAX_GRAMS, MAX_ITEM_KCAL = 2000.0, 3000.0

SYSTEM = """You are a careful nutrition analyst. You look at a photo of a meal (and an optional \
caption from the user) and estimate what was eaten. Reply with ONE JSON object and nothing else.

Schema:
{"is_food": true|false,
 "meal_type": "breakfast"|"lunch"|"dinner"|"snack"|"unknown",
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
- If the image shows no food or drink, return {"is_food": false, "items": [], "confidence": 0, "notes": "..."}.
"""


class AnalysisError(Exception):
    pass


def prepare_image(data: bytes) -> bytes:
    """Apply EXIF rotation, flatten to RGB, downscale to MAX_SIDE, return JPEG bytes."""
    try:
        img = Image.open(io.BytesIO(data))
        img = ImageOps.exif_transpose(img)
    except Exception as e:  # PIL raises many types for bad input
        raise AnalysisError(f"not a readable image: {e}") from e
    if img.mode != "RGB":
        img = img.convert("RGB")
    img.thumbnail((MAX_SIDE, MAX_SIDE))
    out = io.BytesIO()
    img.save(out, "JPEG", quality=85)
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


async def analyze_meal(image: bytes | None = None, caption: str = "", llm: LLM | None = None) -> dict:
    """Analyse a meal from a photo and/or caption. Returns a validated analysis dict."""
    caption = (caption or "").strip()
    if image is None and not caption:
        raise AnalysisError("need a photo or a description")
    llm = llm or LLM()
    prompt = "Analyse this meal." if image is not None else "Analyse this meal from the description only."
    if caption:
        prompt += f"\nUser caption: {caption}"
    content = [{"type": "text", "text": prompt}]
    if image is not None:
        content.append(image_part(prepare_image(image)))
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
def store_meal(db, analysis: dict, *, photo: bytes | None, caption: str, photos_dir: Path,
               ts: int | None = None, source: str = "telegram") -> int:
    """Insert a pending meal with its items; save the prepared photo. Returns meal id."""
    ts = int(ts or time.time())
    t = analysis["totals"]
    cur = db.execute(
        "INSERT INTO meals(ts, caption, meal_type, kcal, protein_g, carbs_g, fat_g, fiber_g, confidence,"
        " status, source, raw_json) VALUES(?,?,?,?,?,?,?,?,?,'pending',?,?)",
        (ts, caption or None, analysis["meal_type"], t["kcal"], t["protein_g"], t["carbs_g"], t["fat_g"],
         t["fiber_g"], analysis["confidence"], source, json.dumps(analysis)))
    mid = cur.lastrowid
    db.executemany(
        "INSERT INTO meal_items(meal_id, name, grams, kcal, protein_g, carbs_g, fat_g) VALUES(?,?,?,?,?,?,?)",
        [(mid, i["name"], i["grams"], i["kcal"], i["protein_g"], i["carbs_g"], i["fat_g"])
         for i in analysis["items"]])
    if photo:
        d = time.localtime(ts)
        rel = Path(f"{d.tm_year}/{d.tm_mon:02d}/{mid}.jpg")
        (photos_dir / rel).parent.mkdir(parents=True, exist_ok=True)
        (photos_dir / rel).write_bytes(prepare_image(photo))
        db.execute("UPDATE meals SET photo_path=? WHERE id=?", (str(rel), mid))
    db.commit()
    return mid


def set_status(db, meal_id: int, status: str) -> bool:
    if status not in ("pending", "confirmed", "discarded"):
        raise ValueError(status)
    cur = db.execute("UPDATE meals SET status=? WHERE id=?", (status, meal_id))
    db.commit()
    return cur.rowcount == 1


def _cli():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    path = Path(sys.argv[1])
    image = path.read_bytes() if path.suffix.lower() != ".txt" else None
    caption = " ".join(sys.argv[2:]) or (path.read_text() if image is None else "")
    try:
        print(json.dumps(asyncio.run(analyze_meal(image, caption)), indent=2))
    except Exception as e:  # AnalysisError / LLMError: show a message, not a traceback
        sys.exit(f"error: {e}")


if __name__ == "__main__":
    _cli()
