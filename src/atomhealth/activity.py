"""Read side of the Apple Health data the iPhone syncs (daily activity, workouts, other apps' nutrition).

The sync layer (`sync.py`) stores the rows; this module shapes them for the dashboard's Activity tab,
the Overview card and the Nutrition note. Nothing here writes to the database.
"""
import time

FEED_DAYS = 400        # daily rows sent to the dashboard (older history stays in SQLite)
FEED_WORKOUTS = 600
MAX_MINUTES = 24 * 60

# HKWorkoutActivityType raw values (the iPhone app sends the number as a string) -> (label, group).
# Groups drive the colour chip in the UI: cardio | strength | mind | sport | outdoor | other
_TYPES = {
    1: ("American football", "sport"), 2: ("Archery", "sport"), 3: ("Australian football", "sport"),
    4: ("Badminton", "sport"), 5: ("Baseball", "sport"), 6: ("Basketball", "sport"), 7: ("Bowling", "sport"),
    8: ("Boxing", "strength"), 9: ("Climbing", "outdoor"), 10: ("Cricket", "sport"),
    11: ("Cross training", "strength"), 12: ("Curling", "sport"), 13: ("Cycling", "cardio"),
    14: ("Dance", "cardio"), 15: ("Dance training", "cardio"), 16: ("Elliptical", "cardio"),
    17: ("Equestrian", "outdoor"), 18: ("Fencing", "sport"), 19: ("Fishing", "outdoor"),
    20: ("Functional strength", "strength"), 21: ("Golf", "outdoor"), 22: ("Gymnastics", "strength"),
    23: ("Handball", "sport"), 24: ("Hiking", "outdoor"), 25: ("Hockey", "sport"), 26: ("Hunting", "outdoor"),
    27: ("Lacrosse", "sport"), 28: ("Martial arts", "strength"), 29: ("Mind and body", "mind"),
    30: ("Mixed cardio", "cardio"), 31: ("Paddle sports", "outdoor"), 32: ("Play", "other"),
    33: ("Recovery", "mind"), 34: ("Racquetball", "sport"), 35: ("Rowing", "cardio"), 36: ("Rugby", "sport"),
    37: ("Running", "cardio"), 38: ("Sailing", "outdoor"), 39: ("Skating", "outdoor"), 40: ("Snow sports", "outdoor"),
    41: ("Soccer", "sport"), 42: ("Softball", "sport"), 43: ("Squash", "sport"), 44: ("Stair climbing", "cardio"),
    45: ("Surfing", "outdoor"), 46: ("Swimming", "cardio"), 47: ("Table tennis", "sport"), 48: ("Tennis", "sport"),
    49: ("Track and field", "cardio"), 50: ("Strength training", "strength"), 51: ("Volleyball", "sport"),
    52: ("Walking", "outdoor"), 53: ("Water fitness", "cardio"), 54: ("Water polo", "sport"),
    55: ("Water sports", "outdoor"), 56: ("Wrestling", "strength"), 57: ("Yoga", "mind"), 58: ("Barre", "strength"),
    59: ("Core training", "strength"), 60: ("Cross-country skiing", "outdoor"), 61: ("Downhill skiing", "outdoor"),
    62: ("Flexibility", "mind"), 63: ("HIIT", "cardio"), 64: ("Jump rope", "cardio"), 65: ("Kickboxing", "strength"),
    66: ("Pilates", "mind"), 67: ("Snowboarding", "outdoor"), 68: ("Stairs", "cardio"), 69: ("Step training", "cardio"),
    70: ("Wheelchair walk", "outdoor"), 71: ("Wheelchair run", "cardio"), 72: ("Tai chi", "mind"),
    73: ("Mixed cardio", "cardio"), 74: ("Hand cycling", "cardio"), 75: ("Disc sports", "sport"),
    76: ("Fitness gaming", "other"), 77: ("Cardio dance", "cardio"), 78: ("Social dance", "cardio"),
    79: ("Pickleball", "sport"), 80: ("Cooldown", "mind"), 82: ("Swim bike run", "cardio"),
    83: ("Transition", "cardio"), 84: ("Diving", "outdoor"), 3000: ("Other", "other"),
}


def workout_type(raw):
    """(label, group) for a raw HealthKit type number, or a name such as 'running'/'traditionalStrengthTraining'."""
    if raw is None or raw == "":
        return "Workout", "other"
    s = str(raw).strip()
    if s.lstrip("-").isdigit():
        return _TYPES.get(int(s), ("Workout", "other"))
    words = "".join(f" {c.lower()}" if c.isupper() else c for c in s.replace("_", " ")).strip()
    label = words[:1].upper() + words[1:]
    low = s.lower()
    for _, (name, group) in _TYPES.items():
        if name.lower().replace(" ", "") == low.replace("_", "").replace(" ", ""):
            return name, group
    return label[:40] or "Workout", "other"


def _round(v, n=0):
    return None if v is None else round(v, n)


def feed(db, now=None):
    """Everything the Activity UI needs, ascending daily rows and newest-first workouts.

    days[]: day, active_kcal, basal_kcal, steps, exercise_min, resting_hr, hrv, vo2max (from Health), logged_kcal (meals confirmed on this Mac),
    other_kcal (nutrition other Health apps wrote). The two intake sources never overlap by design (see sync.py).
    """
    now = now or time.time()
    cutoff_day = time.strftime("%Y-%m-%d", time.localtime(now - FEED_DAYS * 86400))
    days = {}
    for r in db.execute("SELECT day, active_kcal, basal_kcal, steps, exercise_min, resting_hr, hrv, vo2max "
                       "FROM activity_days WHERE day>=?", (cutoff_day,)):
        days[r["day"]] = {"day": r["day"], "active_kcal": _round(r["active_kcal"]), "basal_kcal": _round(r["basal_kcal"]),
                          "steps": r["steps"], "exercise_min": _round(r["exercise_min"]), "resting_hr": _round(r["resting_hr"]),
                          "hrv": _round(r["hrv"]), "vo2max": _round(r["vo2max"], 1)}
    for r in db.execute("SELECT day, kcal FROM nutrition_days WHERE day>=?", (cutoff_day,)):
        days.setdefault(r["day"], {"day": r["day"]})["other_kcal"] = _round(r["kcal"])
    if days:
        first = min(days)
        for r in db.execute("SELECT date(ts,'unixepoch','localtime') AS day, SUM(kcal) AS kcal FROM meals "
                            "WHERE status='confirmed' AND kcal IS NOT NULL AND date(ts,'unixepoch','localtime')>=? GROUP BY day",
                            (first,)):
            if r["day"] in days:   # intake is only interesting next to burn data
                days[r["day"]]["logged_kcal"] = _round(r["kcal"])
    workouts = []
    for r in db.execute("SELECT * FROM workouts WHERE start_ts>=? ORDER BY start_ts DESC LIMIT ?",
                        (int(now - FEED_DAYS * 86400), FEED_WORKOUTS)):
        label, group = workout_type(r["type"])
        mins = round((r["end_ts"] - r["start_ts"]) / 60) if r["end_ts"] and r["end_ts"] >= r["start_ts"] else None
        workouts.append({"id": r["sync_id"], "ts": r["start_ts"], "minutes": mins if mins is None or mins <= MAX_MINUTES else None,
                         "type": label, "group": group, "kcal": _round(r["kcal"]),
                         "km": None if r["distance_m"] is None else round(r["distance_m"] / 1000, 2)})
    upd = db.execute("SELECT MAX(u) FROM (SELECT MAX(updated_at) u FROM activity_days UNION ALL SELECT MAX(updated_at) FROM workouts "
                     "UNION ALL SELECT MAX(updated_at) FROM nutrition_days)").fetchone()[0]
    return {"days": [days[d] for d in sorted(days)], "workouts": workouts, "updated": upd,
            "today": time.strftime("%Y-%m-%d", time.localtime(now))}
