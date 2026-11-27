import importlib.util
import os
import sqlite3
import time
from datetime import datetime

_spec = importlib.util.spec_from_file_location(
    "analyze_inquiry", os.path.join(os.path.dirname(__file__), "..", "scripts", "analyze_inquiry.py"))
ai = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ai)

DAY = "2026-11-17"
T0 = int(datetime.strptime(DAY, "%Y-%m-%d").timestamp()) + 12 * 3600


def _db():
    db = sqlite3.connect(":memory:")
    db.row_factory = sqlite3.Row
    db.executescript("""
    CREATE TABLE advice(id INTEGER PRIMARY KEY, ts INT, day TEXT, kind TEXT, question TEXT, headline TEXT,
      text TEXT, used_llm INT, meal_id INT, source TEXT, basis TEXT);
    CREATE TABLE meals(id INTEGER PRIMARY KEY, ts INT, caption TEXT, kcal REAL, protein_g REAL,
      status TEXT DEFAULT 'confirmed', source TEXT);
    CREATE TABLE meal_photos(id INTEGER PRIMARY KEY, meal_id INT, idx INT, data BLOB);
    """)
    return db


def _ask(db, i, ts, q="What is my activity today?", text="a", basis="1:180:6"):
    db.execute("INSERT INTO advice VALUES(?,?,?,?,?,?,?,1,NULL,'phone',?)", (i, ts, DAY, "ask", q, "h", text, basis))


def test_single_ask_has_no_reruns():
    db = _db()
    _ask(db, 1, T0)
    rows, notes = ai.find_reruns(db, db.execute("SELECT * FROM advice WHERE id=1").fetchone())
    assert len(rows) == 1 and notes == []


def test_rerun_burst_and_identical_answer_flagged():
    db = _db()
    _ask(db, 1, T0, text="same")
    _ask(db, 2, T0 + 30, q="  what is my ACTIVITY today? ", text="same")
    _ask(db, 3, T0 + 5000, text="other", basis="2:400:20")
    rows, notes = ai.find_reruns(db, db.execute("SELECT * FROM advice WHERE id=3").fetchone())
    text = " ".join(notes)
    assert [x["id"] for x in rows] == [1, 2, 3]
    assert "3 times" in text and "1 rerun(s)" in text and "identical" in text and "basis differs" in text


def test_same_photo_in_two_meals_is_a_duplicate_group():
    db = _db()
    for mid, ts in ((1, T0), (2, T0 + 60)):
        db.execute("INSERT INTO meals VALUES(?,?,?,?,?,?,?)", (mid, ts, "", 500, 30, "confirmed", "phone"))
        db.execute("INSERT INTO meal_photos(meal_id,idx,data) VALUES(?,0,?)", (mid, b"jpegbytes"))
    db.execute("INSERT INTO meals VALUES(3,?,?,?,?,?,?)", (T0 + 7200, "", 300, 10, "confirmed", "phone"))
    groups = ai.find_duplicate_meals(db, DAY)
    assert len(groups) == 1 and [m["id"] for m in groups[0][1]] == [1, 2]
    assert ai.double_counted_kcal(groups) == 500


def test_same_caption_and_macros_close_in_time_but_not_far_apart():
    db = _db()
    db.execute("INSERT INTO meals VALUES(1,?,'Oatmeal',350,12,'confirmed','phone')", (T0,))
    db.execute("INSERT INTO meals VALUES(2,?,'oatmeal',350,12,'pending','telegram')", (T0 + 300,))
    db.execute("INSERT INTO meals VALUES(3,?,'Oatmeal',350,12,'confirmed','phone')", (T0 + 6 * 3600,))
    groups = ai.find_duplicate_meals(db, DAY)
    assert len(groups) == 1 and [m["id"] for m in groups[0][1]] == [1, 2]


def test_discarded_duplicate_is_not_double_counted():
    db = _db()
    db.execute("INSERT INTO meals VALUES(1,?,'Soup',200,8,'confirmed','phone')", (T0,))
    db.execute("INSERT INTO meals VALUES(2,?,'Soup',200,8,'discarded','phone')", (T0 + 60,))
    assert ai.double_counted_kcal(ai.find_duplicate_meals(db, DAY)) == 0
