"""Graphics for the phone chat: gauges, rings, bar charts and line charts attached to bot messages.

The wire format (see phonechat.py) is plain numbers, drawn by the app; Telegram never sees it. The coach (the LLM)
does not write numbers: it asks for a NAMED chart with a token like `[[visual kcal7d]]` at the end of its answer and
this module builds the data from the database, so a chart can never show an invented value.

    today     calories against the daily limit (green / amber / red) + protein, carbs and fat bars
    ring      the same calorie status as a ring
    macros    protein, carbs, fat against their targets
    kcal7d    kcal per day, last 7 days (bars, target line)        kcal14d  same, 14 days (line)
    protein7d protein grams per day, last 7 days (bars)
    steps7d   Apple Health steps per day, last 7 days (bars)       active7d active kcal per day (bars)
    weight30d weight, last 30 days (line)                          weight90d  last 90 days
"""
import re
import time
from datetime import datetime

from . import advisor, food

MAX_VISUALS = 8
MAX_POINTS = 31
TOKEN = re.compile(r"\[\[\s*visual[\s:=]+([A-Za-z0-9_-]+)\s*\]\]", re.I)


def status_for(value, limit):
    ratio = value / limit if limit else 0
    return "ok" if ratio <= 1 else "warn" if ratio <= 1.1 else "over"


def extract(text, limit=3):
    """(text without the tokens, up to `limit` distinct known chart names in the order asked)."""
    names = []
    for n in TOKEN.findall(text or ""):
        n = n.lower().replace("_", "")
        if n in SOURCES and n not in names:
            names.append(n)
    return TOKEN.sub("", text or "").rstrip(), names[:limit]


def clean(v):
    """One visual in wire form, or None. The phone draws whatever arrives, so keep it small and sane."""
    try:
        t = v["type"]
        if t in ("gauge", "ring"):
            g = {"type": t, "label": str(v["label"])[:40], "value": float(v["value"]), "max": float(v["max"]),
                 "unit": str(v.get("unit", ""))[:8]}
            if v.get("status") in ("ok", "warn", "over"):
                g["status"] = v["status"]
            return g if g["max"] > 0 and g["value"] >= 0 else None
        if t in ("bars", "line"):
            pts = [{"label": str(p["label"])[:10], "value": float(p["value"])} for p in v["points"][:MAX_POINTS]]
            if len(pts) < 2:
                return None
            c = {"type": t, "label": str(v["label"])[:40], "unit": str(v.get("unit", ""))[:8], "points": pts}
            if v.get("target") is not None and float(v["target"]) > 0:
                c["target"] = float(v["target"])
            return c
    except (KeyError, TypeError, ValueError, AttributeError):
        pass
    return None


def clean_all(visuals):
    return [c for c in (clean(v) for v in visuals or []) if c][:MAX_VISUALS]


# ---------- builders: each returns a list of visuals (possibly empty) ----------
def _today(db, target, plan):
    start = food.day_start()
    rows = food.meals_between(db, start, start + 86400)
    return start, food.sum_meals(rows) if rows else None


def _calories(db, target, plan, kind="gauge"):
    _, t = _today(db, target, plan)
    if not t or not target:
        return []
    return [{"type": kind, "label": "Calories", "value": round(t["kcal"]), "max": round(target), "unit": "kcal",
             "status": status_for(t["kcal"], target)}]


def _macros(db, target, plan):
    _, t = _today(db, target, plan)
    macro = {m["key"]: m["g"] for m in (plan or {}).get("macros", [])}
    if not t:
        return []
    return [{"type": "gauge", "label": label, "value": round(t[f"{key}_g"]), "max": round(macro[key]), "unit": "g"}
            for key, label in (("protein", "Protein"), ("carbs", "Carbs"), ("fat", "Fat")) if macro.get(key)]


def _series(db, days, key, label, unit, target=None, kind="bars"):
    pts = [{"label": datetime.strptime(d["date"], "%Y-%m-%d").strftime("%a" if days <= 7 else "%d.%m"),
            "value": round(d[key])} for d in advisor.daily_series(db, days)]
    return [{"type": kind, "label": label, "unit": unit, "points": pts, **({"target": target} if target else {})}]


def _activity(db, column, label, unit, days=7):
    days_l = [m.strftime("%Y-%m-%d") for m in advisor._midnights(time.time(), days)]
    rows = {r[0]: r[1] for r in db.execute(f"SELECT day, {column} FROM activity_days WHERE day>=? AND day<=?",
                                          (days_l[0], days_l[-1]))}
    pts = [{"label": datetime.strptime(d, "%Y-%m-%d").strftime("%a"), "value": round(rows.get(d) or 0)} for d in days_l]
    return [{"type": "bars", "label": label, "unit": unit, "points": pts}] if any(p["value"] for p in pts) else []


def _weight(db, days):
    rows = db.execute("SELECT ts, weight FROM readings WHERE ts>=? ORDER BY ts", (time.time() - days * 86400,)).fetchall()
    per_day = {}
    for r in rows:
        per_day[datetime.fromtimestamp(r[0]).strftime("%d.%m")] = round(r[1], 1)       # the day's last reading
    pts = [{"label": k, "value": v} for k, v in per_day.items()]
    return [{"type": "line", "label": f"Weight, {days} days", "unit": "kg", "points": pts}] if len(pts) >= 2 else []


SOURCES = {
    "today": lambda db, tg, pl: _calories(db, tg, pl) + _macros(db, tg, pl),
    "ring": lambda db, tg, pl: _calories(db, tg, pl, "ring"),
    "macros": _macros,
    "kcal7d": lambda db, tg, pl: _series(db, 7, "kcal", "Calories, 7 days", "kcal", tg),
    "kcal14d": lambda db, tg, pl: _series(db, 14, "kcal", "Calories, 14 days", "kcal", tg, "line"),
    "protein7d": lambda db, tg, pl: _series(db, 7, "protein_g", "Protein, 7 days", "g"),
    "steps7d": lambda db, tg, pl: _activity(db, "steps", "Steps, 7 days", ""),
    "active7d": lambda db, tg, pl: _activity(db, "active_kcal", "Active energy, 7 days", "kcal"),
    "weight30d": lambda db, tg, pl: _weight(db, 30),
    "weight90d": lambda db, tg, pl: _weight(db, 90),
}


def build(names, db, target, plan):
    out = []
    for n in names:
        try:
            out += clean_all(SOURCES[n](db, target, plan))
        except Exception:        # a chart must never break the answer it decorates
            continue
    return out[:MAX_VISUALS]
