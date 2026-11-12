"""Diet coaching: numbers are computed here in code; the LLM only writes the commentary around them.

  snapshot()  -> JSON-able facts (today, last 7 days, weight trend, real maintenance, suggested target)
  report()    -> {"headline": deterministic stats line, "text": LLM commentary, "used_llm": bool}

If the model is unavailable the commentary falls back to a short rule-based text, so scheduled
summaries still go out. Safety floors from bodycomp.nutrition() are never undercut.
"""
import json
import re
import time
from datetime import datetime, timedelta

from . import food
from .bodycomp import KCAL_PER_KG, compute as body_compute
from .llm import LLM, LLMError

COMPLETE_DAY_KCAL = 800        # a day only counts as "fully logged" above this
MIN_LOGGED_DAYS = 5            # needed before the real maintenance estimate is trusted
MIN_SPAN_DAYS = 7              # weight readings must cover this many days
MIN_CHANGE_KCAL = 100          # smaller target corrections are not worth mentioning
LIMITS = {"meal": 60, "day": 110, "week": 170, "ask": 120}   # words

SYSTEM = """You are a friendly, practical nutrition coach inside a personal health app. You receive a JSON \
snapshot whose numbers were already computed by the app.

Rules:
- Use ONLY numbers that appear in the JSON. Never invent, recompute or round them differently.
- Give 1-3 concrete, small tweaks (foods, portions, timing, protein, fibre, drinks), based on what the user \
actually eats (recent_foods). No generic lectures.
- If suggested_target is present, mention it exactly as given and say why in one sentence.
- Encouraging, not preachy. No medical claims or diagnosis. If something looks unsafe, suggest talking to a \
doctor or dietitian.
- body_trends summarises weight, BMI and the estimated body composition (fat %, fat kg, lean kg, muscle kg, \
water %) over 7 and 30 days: 'now', 'change' (negative = down) and 'direction'. Mention the relevant trends \
briefly for the day/week review (e.g. weight and fat down, lean mass stable) and tie them to the advice. \
Fat %, lean and muscle are formula ESTIMATES from weight, height, age and sex, so treat them as direction \
only. A null window means too little data: do not guess it.
- If few days are logged (days_logged), say the advice will sharpen with more logging.
- Plain text only: no markdown, no headings, no bullet symbols other than '-'. At most one emoji.
- Reply in the language of the user's question if there is one, otherwise English.
- Stay within the word limit you are given."""


def _midnights(now, days):
    d0 = datetime.fromtimestamp(now).replace(hour=0, minute=0, second=0, microsecond=0)
    return [d0 - timedelta(days=i) for i in range(days - 1, -1, -1)]


def daily_series(db, days, now=None):
    """Confirmed intake per local day, oldest first, today last."""
    now = now or time.time()
    out = []
    for m in _midnights(now, days):
        rows = food.meals_between(db, int(m.timestamp()), int((m + timedelta(days=1)).timestamp()))
        out.append({"date": m.strftime("%Y-%m-%d"), **food.sum_meals(rows), "meals": len(rows)})
    return out


def weight_trend(db, now=None, days=14):
    """Least-squares weight slope in kg/week over the window, or None if the data is too thin."""
    now = now or time.time()
    rows = db.execute("SELECT ts, weight FROM readings WHERE ts>=? AND ts<=? ORDER BY ts",
                      (now - days * 86400, now)).fetchall()
    if len(rows) < 3:
        return None
    xs = [(r[0] - rows[0][0]) / 86400 for r in rows]
    ys = [r[1] for r in rows]
    span = xs[-1]
    if span < MIN_SPAN_DAYS:
        return None
    mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
    sxx = sum((x - mx) ** 2 for x in xs)
    if sxx == 0:
        return None
    slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx      # kg per day
    return {"kg_per_week": round(slope * 7, 2), "readings": len(rows), "span_days": round(span, 1)}


TREND_FIELDS = ("weight", "bmi", "fat_pct", "fat_kg", "lean_kg", "muscle_kg", "water_pct")
TREND_FLAT = {"weight": 0.2, "bmi": 0.1, "fat_pct": 0.2, "fat_kg": 0.2, "lean_kg": 0.2, "muscle_kg": 0.2,
              "water_pct": 0.3}      # changes smaller than this are called "stable" (scale noise)


def body_trends(db, profile, now=None, windows=(7, 30)):
    """Weight/BMI/body-composition summary per window: latest value, change vs the window start
    (daily means, so one noisy weigh-in does not dominate) and direction. Window is None if < 2 days of data."""
    now = now or time.time()
    out = {}
    for days in windows:
        rows = db.execute("SELECT ts, weight FROM readings WHERE ts>=? AND ts<=? ORDER BY ts",
                          (now - days * 86400, now)).fetchall()
        byday = {}
        for ts, w in rows:
            byday.setdefault(datetime.fromtimestamp(ts).strftime("%Y-%m-%d"), []).append(w)
        if len(byday) < 2:
            out[f"last_{days}_days"] = None
            continue
        means = [sum(v) / len(v) for _, v in sorted(byday.items())]
        first, last = body_compute(means[0], profile), body_compute(means[-1], profile)
        if not first or not last:
            out[f"last_{days}_days"] = None
            continue
        first["weight"], last["weight"] = round(means[0], 1), round(means[-1], 1)
        d = {"days_with_readings": len(means)}
        for f in TREND_FIELDS:
            ch = round(last[f] - first[f], 1)
            d[f] = {"from": first[f], "now": last[f], "change": ch,
                    "direction": "stable" if abs(ch) < TREND_FLAT[f] else "up" if ch > 0 else "down"}
        out[f"last_{days}_days"] = d
    return out


def safety_floor(plan):
    male = plan.get("sex", "male") == "male"
    return max(1500 if male else 1200, 0.9 * (plan.get("bmr") or 0))


def real_maintenance(series, trend, plan):
    """Maintenance kcal implied by what was actually eaten and how weight actually moved.

    maintenance = average intake - (kg/week * 7700 / 7). Needs enough fully logged days and a weight trend;
    values wildly out of line with the person's BMR are rejected as noise (partial logging, water swings).
    """
    done = [d for d in series[:-1] if d["kcal"] >= COMPLETE_DAY_KCAL]          # today is not finished yet
    if len(done) < MIN_LOGGED_DAYS or not trend:
        return None
    avg = sum(d["kcal"] for d in done) / len(done)
    est = avg - trend["kg_per_week"] * KCAL_PER_KG / 7
    bmr = plan.get("bmr") or 0
    if bmr and not (bmr <= est <= bmr * 2.5):
        return {"avg_intake": round(avg), "days_logged": len(done), "kcal": None, "note": "inconsistent data"}
    return {"avg_intake": round(avg), "days_logged": len(done), "kcal": round(est)}


def suggest_target(plan, real):
    """New daily target = real maintenance + the planned deficit/surplus; never below the safety floor."""
    if not plan.get("kcal") or not real or not real.get("kcal"):
        return None
    new = real["kcal"] + plan.get("adjust", 0)
    new = max(new, safety_floor(plan))
    new = int(round(new / 10.0) * 10)
    delta = new - plan["kcal"]
    if abs(delta) < MIN_CHANGE_KCAL:
        return None
    return {"kcal": new, "change": delta, "real_maintenance_kcal": real["kcal"],
            "planned_maintenance_kcal": plan.get("maintenance")}


def recent_foods(db, now=None, days=7, limit=12):
    now = now or time.time()
    rows = db.execute(
        "SELECT i.name, COUNT(*) n, SUM(i.kcal) kcal FROM meal_items i JOIN meals m ON m.id=i.meal_id "
        "WHERE m.status='confirmed' AND m.ts>=? GROUP BY lower(i.name) ORDER BY kcal DESC LIMIT ?",
        (now - days * 86400, limit)).fetchall()
    return [{"name": r[0], "times": r[1], "kcal": round(r[2] or 0)} for r in rows]


def snapshot(db, profile, plan, weight, now=None, meal=None):
    """Everything the coach may talk about, with all numbers precomputed."""
    now = now or time.time()
    plan = {**plan, "sex": profile.get("sex", "male")} if plan else {}
    series = daily_series(db, 15, now)
    trend = weight_trend(db, now)
    real = real_maintenance(series, trend, plan) if plan else None
    week = series[-7:]
    logged = [d for d in week if d["meals"]]
    macro_t = {m["key"]: m["g"] for m in plan.get("macros", [])}
    snap = {
        "goal": plan.get("goal"), "daily_target_kcal": plan.get("kcal"),
        "macro_targets_g": macro_t or None, "fibre_target_g": (plan.get("limits") or {}).get("fiber_g"),
        "weight_kg": weight, "target_weight_kg": plan.get("target_weight"),
        "sex": profile.get("sex"), "age": profile.get("age"),
        "today": {k: series[-1][k] for k in ("kcal", "protein_g", "carbs_g", "fat_g", "fiber_g", "meals")},
        "last_7_days": [{"date": d["date"], "kcal": round(d["kcal"]), "protein_g": round(d["protein_g"])}
                        for d in week],
        "days_logged": len(logged),
        "avg_kcal_logged_days": round(sum(d["kcal"] for d in logged) / len(logged)) if logged else None,
        "weight_trend": trend, "body_trends": body_trends(db, profile, now), "real_maintenance": real,
        "suggested_target": suggest_target(plan, real),
        "recent_foods": recent_foods(db, now),
    }
    if meal:
        snap["this_meal"] = {"type": meal["meal_type"], "totals": meal["totals"],
                             "items": [{"name": i["name"], "grams": i["grams"], "kcal": i["kcal"]} for i in meal["items"]]}
    return snap


# ---------- text ----------
def _k(v):
    return f"{v:,.0f}"


def headline(kind, s):
    """Deterministic stats line(s): these numbers never come from the model."""
    t, tgt = s["today"], s.get("daily_target_kcal")
    lines = []
    if kind == "meal" and s.get("this_meal"):
        m = s["this_meal"]["totals"]
        share = f" ({m['kcal'] / tgt * 100:.0f}% of your daily target)" if tgt else ""
        lines.append(f"This meal: {_k(m['kcal'])} kcal{share}.")
    if kind in ("meal", "day", "ask") or not tgt:
        left = f" · {_k(abs(tgt - t['kcal']))} {'left' if tgt >= t['kcal'] else 'over'}" if tgt else ""
        lines.append(f"Today: {_k(t['kcal'])}{' / ' + _k(tgt) if tgt else ''} kcal{left} · protein {t['protein_g']:.0f} g")
    if kind == "week":
        if s["avg_kcal_logged_days"] is not None:
            lines.append(f"Last 7 days: average {_k(s['avg_kcal_logged_days'])} kcal on {s['days_logged']} logged day(s)"
                         + (f", target {_k(tgt)}" if tgt else "") + ".")
        else:
            lines.append("No meals logged in the last 7 days.")
        w = s.get("weight_trend")
        lines.append(f"Weight trend: {w['kg_per_week']:+.2f} kg/week." if w
                     else "Weight trend: not enough readings yet (need 3+ over a week).")
    if kind in ("day", "week") and s.get("suggested_target"):
        g = s["suggested_target"]
        lines.append(f"🎯 Suggested daily target: {_k(g['kcal'])} kcal ({g['change']:+,} vs now). "
                     f"Your real maintenance looks like {_k(g['real_maintenance_kcal'])} kcal.")
    return "\n".join(lines)


def fallback_text(kind, s):
    """Rule-based commentary used when the model is unreachable."""
    tgt, t = s.get("daily_target_kcal"), s["today"]
    if not tgt:
        return "Set your height and take a weight reading to get a personal calorie target."
    left = tgt - t["kcal"]
    prot = (s.get("macro_targets_g") or {}).get("protein")
    bits = []
    if left < -150:
        bits.append("You're over today's target; lighter, protein-rich choices for the next meal will help.")
    elif left > 0 and kind in ("meal", "day"):
        bits.append(f"You have room for about {_k(left)} kcal more today.")
    if prot and t["protein_g"] < prot * 0.7:
        bits.append(f"Protein is behind ({t['protein_g']:.0f} of {prot} g): add eggs, yoghurt, fish, poultry or legumes.")
    if kind == "week" and s["days_logged"] < 5:
        bits.append("Log more days for a reliable weekly picture.")
    return " ".join(bits) or "You're on track. Keep logging."


def _prompt(kind, s, question=None):
    limit = LIMITS[kind]
    ask = {"meal": "Comment on the meal in 'this_meal' in the context of the whole day.",
           "day": "Summarise today and say what to adjust tomorrow.",
           "week": "Review the week: what went well, the main issue, and what to change next week. "
                   "Explain the suggested_target if present.",
           "ask": f"Answer the user's question: {question!r}. If it is not about food, nutrition or this "
                  "health data, politely say you can only help with that."}[kind]
    return f"{ask}\nMaximum {limit} words.\n\nJSON snapshot:\n{json.dumps(s, ensure_ascii=False)}"


def _clean(text):
    text = re.sub(r"<think>.*?</think>", "", text or "", flags=re.S).strip()
    text = re.sub(r"[*_`#]{1,3}", "", text)            # markdown the model was told not to use
    return text[:1500].strip()


async def report(kind, s, question=None, llm=None):
    """Return {"headline", "text", "used_llm"}. /ask re-raises LLMError (a canned answer would be wrong)."""
    llm = llm or LLM()
    head = headline(kind, s)
    try:
        text = _clean(await llm.chat([{"role": "system", "content": SYSTEM},
                                      {"role": "user", "content": _prompt(kind, s, question)}],
                                     max_tokens=700, temperature=0.5))
        if len(text) < 15:
            raise LLMError("empty advice")
        return {"headline": head, "text": text, "used_llm": True}
    except LLMError:
        if kind == "ask":
            raise
        return {"headline": head, "text": fallback_text(kind, s), "used_llm": False}


# ---------- persistence: every message is kept so the dashboard can show "today's advice" ----------
def save_advice(db, kind, r, *, question=None, meal_id=None, source="api", ts=None):
    ts = int(ts or time.time())
    cur = db.execute("INSERT INTO advice(ts, day, kind, question, headline, text, used_llm, meal_id, source) "
                     "VALUES(?,?,?,?,?,?,?,?,?)",
                     (ts, datetime.fromtimestamp(ts).strftime("%Y-%m-%d"), kind, question, r["headline"], r["text"],
                      1 if r.get("used_llm") else 0, meal_id, source))
    db.commit()
    return cur.lastrowid


def purge_for_meal(db, meal_id, meal_ts) -> int:
    """Drop advice that was written about a meal that no longer exists: its own tip, and the daily
    summaries of that day generated after it was logged (they counted its calories). Questions and
    weekly reviews are kept. Returns how many messages were removed."""
    day = datetime.fromtimestamp(meal_ts).strftime("%Y-%m-%d")
    cur = db.execute("DELETE FROM advice WHERE meal_id=? OR (kind='day' AND day=? AND ts>=?)",
                     (meal_id, day, meal_ts))
    db.commit()
    return cur.rowcount


def _row(r):
    return {"id": r["id"], "ts": r["ts"], "kind": r["kind"], "question": r["question"], "headline": r["headline"],
            "text": r["text"], "used_llm": bool(r["used_llm"]), "source": r["source"]}


def feed(db, now=None, limit=20):
    """Today's advice messages (newest first) and the most recent weekly review of the last 8 days."""
    now = now or time.time()
    day = datetime.fromtimestamp(now).strftime("%Y-%m-%d")
    today = [_row(r) for r in db.execute("SELECT * FROM advice WHERE day=? ORDER BY ts DESC, id DESC LIMIT ?", (day, limit))]
    wk = db.execute("SELECT * FROM advice WHERE kind='week' AND ts>=? ORDER BY ts DESC, id DESC LIMIT 1",
                    (now - 8 * 86400,)).fetchone()
    return {"today": today, "week": _row(wk) if wk else None}
