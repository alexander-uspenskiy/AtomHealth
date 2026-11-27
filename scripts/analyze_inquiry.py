#!/usr/bin/env python3
"""Post-mortem of a coach inquiry: what did the app know when the question was asked, and was it sent to the LLM?

Usage:
  python scripts/analyze_inquiry.py                 # latest 'ask' from the phone
  python scripts/analyze_inquiry.py --id 17         # a specific advice row
  python scripts/analyze_inquiry.py --match activity  # latest question containing 'activity'
  python scripts/analyze_inquiry.py --db data/weight.db

Run it with the project's interpreter (.venv/bin/python): the activity-block step imports atomhealth.advisor,
which needs the project's dependencies (PIL). Read-only: it never writes to the database.
Caveat: 'synced before/after ask' compares activity_days.updated_at, which is overwritten on every re-sync, so
it shows when a day was last refreshed, not when it first arrived.
Checks: reruns of the same question that day, and the same food report (same photo, or same caption + macros
within 30 min) logged more than once.
"""
import argparse, hashlib, json, os, sqlite3, sys, time
from datetime import datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "src"))


def fmt(ts):
    return datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M:%S")


RERUN_WINDOW_S = 600          # the same question again within 10 min counts as a rerun burst
SAME_MEAL_WINDOW_S = 1800     # same caption + macros within 30 min counts as the same food report


def _norm(s):
    return " ".join((s or "").lower().split())


def day_bounds(day):
    """[start, end) epoch seconds of a local calendar day 'YYYY-MM-DD'."""
    start = datetime.strptime(day, "%Y-%m-%d").timestamp()
    return int(start), int(start) + 86400


def find_reruns(db, r):
    """Other 'ask' rows with the same question text (same source, same day) as advice row `r`.
    Returns (rows, notes): rows ordered by time, each with an 'identical answer' flag vs. `r`."""
    q = _norm(r["question"])
    rows = [x for x in db.execute("SELECT * FROM advice WHERE kind=? AND source IS ? AND day=? ORDER BY ts, id",
                                  (r["kind"], r["source"], r["day"])) if _norm(x["question"]) == q]
    notes = []
    if len(rows) > 1:
        notes.append(f"the same question was asked {len(rows)} times on {r['day']}")
        gaps = [b["ts"] - a["ts"] for a, b in zip(rows, rows[1:])]
        if any(g <= RERUN_WINDOW_S for g in gaps):
            notes.append(f"{sum(g <= RERUN_WINDOW_S for g in gaps)} rerun(s) within {RERUN_WINDOW_S // 60} min of the previous one")
        answers = {_norm(x["text"]) for x in rows}
        if len(answers) < len(rows):
            notes.append("some reruns returned a word-for-word identical answer (likely a resend, not a fresh question)")
        if len({x["basis"] for x in rows}) > 1:
            notes.append("the day's meals changed between reruns (basis differs), so the answers are not comparable")
    return rows, notes


def find_duplicate_meals(db, day):
    """Meals on `day` that look like the same food report logged more than once.
    Groups are (reason, [meal rows]). Exact photo matches first, then same caption+macros close in time."""
    lo, hi = day_bounds(day)
    meals = db.execute("SELECT * FROM meals WHERE ts>=? AND ts<? ORDER BY ts, id", (lo, hi)).fetchall()
    by_photo = {}
    for m in meals:
        for p in db.execute("SELECT data FROM meal_photos WHERE meal_id=?", (m["id"],)):
            by_photo.setdefault(hashlib.sha1(bytes(p[0])).hexdigest(), set()).add(m["id"])
    groups, covered = [], set()
    for h, ids in by_photo.items():
        if len(ids) > 1:
            groups.append((f"same photo ({h[:8]})", [m for m in meals if m["id"] in ids]))
            covered |= ids
    for i, a in enumerate(meals):
        for b in meals[i + 1:]:
            if {a["id"], b["id"]} <= covered or b["ts"] - a["ts"] > SAME_MEAL_WINDOW_S:
                continue
            same = (_norm(a["caption"]) == _norm(b["caption"]) and a["kcal"] is not None
                    and round(a["kcal"] or 0) == round(b["kcal"] or 0)
                    and round(a["protein_g"] or 0) == round(b["protein_g"] or 0))
            if same:
                groups.append(("same caption and macros within 30 min", [a, b]))
    return groups


def double_counted_kcal(groups):
    """kcal counted more than once: for each group, everything but the first non-discarded meal."""
    extra = 0.0
    for _, ms in groups:
        live = [m for m in ms if m["status"] != "discarded"]
        extra += sum(m["kcal"] or 0 for m in live[1:])
    return extra


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default=os.path.join(ROOT, "data", "weight.db"))
    ap.add_argument("--id", type=int)
    ap.add_argument("--match", default="")
    ap.add_argument("--source", default="phone")
    a = ap.parse_args()

    db = sqlite3.connect(f"file:{os.path.abspath(a.db)}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    if a.id:
        r = db.execute("SELECT * FROM advice WHERE id=?", (a.id,)).fetchone()
    else:
        r = db.execute("SELECT * FROM advice WHERE kind='ask' AND source=? AND question LIKE ? "
                       "ORDER BY ts DESC, id DESC LIMIT 1", (a.source, f"%{a.match}%")).fetchone()
    if not r:
        sys.exit("no matching inquiry")

    print(f"== Inquiry #{r['id']}  {fmt(r['ts'])}  source={r['source']}  used_llm={r['used_llm']}")
    print(f"Q: {r['question']}\nA: {r['text']}\n")

    # 1. Did the answer claim missing activity data? Compare with what the DB held at that moment.
    ts = r["ts"]
    day = r["day"]
    print("== Apple Health data present in the DB at question time")
    rows = db.execute("SELECT day, active_kcal, steps, updated_at FROM activity_days "
                      "WHERE day<=? ORDER BY day DESC LIMIT 7", (day,)).fetchall()
    for x in rows:
        known = "synced before ask" if x["updated_at"] <= ts else "synced AFTER ask"
        print(f"  {x['day']}  steps={x['steps']}  active_kcal={round(x['active_kcal'] or 0)}  "
              f"updated {fmt(x['updated_at'])}  [{known}]")
    start = ts - 7 * 86400
    wk = db.execute("SELECT COUNT(*) n FROM workouts WHERE start_ts BETWEEN ? AND ?", (start, ts)).fetchone()["n"]
    print(f"  workouts in the 7 days before the ask: {wk}\n")

    # 2. Was this question rerun? (a resend, a retry, or the same ask from several devices)
    print("== Reruns of the same question that day")
    reruns, rerun_notes = find_reruns(db, r)
    for x in reruns:
        mark = "  <- this one" if x["id"] == r["id"] else ""
        print(f"  #{x['id']}  {fmt(x['ts'])}  used_llm={x['used_llm']}  basis={x['basis']}{mark}")
    print("  " + ("; ".join(rerun_notes) if rerun_notes else "asked once, no reruns") + "\n")

    # 3. Was the same food report (photo / meal) logged several times that day?
    print(f"== Duplicate food reports on {day}")
    dup_groups = find_duplicate_meals(db, day)
    for why, ms in dup_groups:
        print(f"  {why}:")
        for m in ms:
            print(f"    meal #{m['id']}  {fmt(m['ts'])}  {m['status']:<9}  {m['source']}  "
                  f"{round(m['kcal'] or 0)} kcal  caption={m['caption']!r}")
    extra_kcal = double_counted_kcal(dup_groups)
    print(f"  {len(dup_groups)} duplicate group(s); about {round(extra_kcal)} kcal counted more than once"
          if dup_groups else "  no duplicate food reports")
    print()

    # 4. Rebuild the activity block exactly as the current code would send it.
    print("== activity block the CURRENT code would put in the LLM snapshot")
    try:
        from atomhealth import advisor
        act = advisor.activity_summary(db, now=ts)
        print(json.dumps(act, ensure_ascii=False, indent=2) if act else "  None (no data)")
    except Exception as e:  # advisor without activity support (older commit)
        act = None
        print(f"  advisor.activity_summary unavailable: {e!r}")

    # 5. Verdict
    print("\n== Verdict")
    if rerun_notes:
        print("  RERUN: " + "; ".join(rerun_notes))
    if dup_groups:
        print(f"  DUPLICATE FOOD: {len(dup_groups)} group(s) of the same food report; the day's totals may be "
              f"inflated by ~{round(extra_kcal)} kcal. Check the bot/phone resend path.")
    said_missing = any(w in (r["text"] or "").lower() for w in ("don't see", "no activity", "not see", "no data"))
    had_data = bool(rows) and any(x["updated_at"] <= ts for x in rows)
    if said_missing and had_data:
        print("  Answer claimed no activity data, but the DB had it. Likely cause: the server that answered was "
              "running code whose snapshot() did not include 'activity' (check `git log -S activity_summary` / "
              "restart the server after deploying), or the prompt rules did not mention it.")
    elif said_missing:
        print("  No activity data had been synced before the ask: check the phone's Health sync.")
    else:
        print("  Answer did not claim missing data; read the text above against the activity block.")
    print(f"  basis={r['basis']} (meals_count:kcal:protein at ask time), headline: {r['headline']!r}")


if __name__ == "__main__":
    main()
