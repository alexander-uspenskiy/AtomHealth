import asyncio
import io
import json
import sqlite3

import pytest
from aiohttp import web
from aiohttp.test_utils import TestServer
from PIL import Image

from atomhealth import food, llm


def _jpeg(size=(2000, 1000), color=(200, 100, 50)):
    b = io.BytesIO()
    Image.new("RGB", size, color).save(b, "JPEG")
    return b.getvalue()


GOOD = {"is_food": True, "meal_type": "lunch", "confidence": 0.7, "notes": "portion guessed",
        "items": [{"name": "rice", "grams": 200, "kcal": 260, "protein_g": 5, "carbs_g": 57, "fat_g": 0.5, "fiber_g": 1},
                  {"name": "chicken", "grams": 120, "kcal": 198, "protein_g": 37, "carbs_g": 0, "fat_g": 4, "fiber_g": 0}]}


def test_prepare_image_downscales_and_rejects_garbage():
    out = Image.open(io.BytesIO(food.prepare_image(_jpeg())))
    assert max(out.size) == food.MAX_SIDE and out.mode == "RGB"
    with pytest.raises(food.AnalysisError):
        food.prepare_image(b"not an image")


def test_validate_sums_totals():
    a = food.validate(GOOD)
    assert a["totals"]["kcal"] == 458 and a["totals"]["protein_g"] == 42 and a["adjusted"] == []


def test_validate_recomputes_inconsistent_kcal():
    raw = json.loads(json.dumps(GOOD))
    raw["items"][0]["kcal"] = 900  # macros say ~252
    a = food.validate(raw)
    assert a["items"][0]["kcal"] == 252 and a["adjusted"]


def test_validate_fills_missing_kcal_and_clamps_junk():
    a = food.validate({"is_food": True, "meal_type": "brunch", "confidence": 5,
                       "items": [{"name": "egg", "grams": "abc", "protein_g": 6, "carbs_g": -3, "fat_g": 5}]})
    it = a["items"][0]
    assert it["kcal"] == 69 and it["grams"] == 0 and it["carbs_g"] == 0
    assert a["meal_type"] == "unknown" and a["confidence"] == 1.0


def test_validate_rejects_empty_and_implausible():
    for bad in ({"is_food": True, "items": []}, [], {"items": [{"name": ""}]},
                {"items": [{"name": "x", "kcal": 99999, "fat_g": 500}]}):
        with pytest.raises(food.AnalysisError):
            food.validate(bad)


def test_not_food():
    a = food.validate({"is_food": False, "notes": "a cat"})
    assert a["is_food"] is False and a["items"] == [] and a["totals"]["kcal"] == 0


def _analyze(replies, image=None, caption=""):
    calls = []

    async def handler(request):
        calls.append(await request.json())
        return web.json_response({"choices": [{"message": {"content": replies[min(len(calls) - 1, len(replies) - 1)]}}]})

    async def go():
        app = web.Application()
        app.router.add_post("/v1/chat/completions", handler)
        async with TestServer(app) as srv:
            c = llm.LLM(base_url=str(srv.make_url("/v1")), model="m", api_key="k", timeout=5)
            return await food.analyze_meal(image, caption, llm=c)
    return asyncio.run(go()), calls


def test_analyze_meal_photo_and_caption():
    out, calls = _analyze([json.dumps(GOOD)], image=_jpeg(), caption="homemade")
    assert out["totals"]["kcal"] == 458
    user = calls[0]["messages"][1]["content"]
    assert "homemade" in user[0]["text"] and user[1]["type"] == "image_url"


def test_analyze_meal_text_only_has_no_image():
    _, calls = _analyze([json.dumps(GOOD)], caption="rice and chicken")
    assert all(p["type"] == "text" for p in calls[0]["messages"][1]["content"])


def test_analyze_retries_once_on_bad_output():
    out, calls = _analyze(['{"is_food": true, "items": []}', json.dumps(GOOD)], caption="x")
    assert len(calls) == 2 and out["is_food"]


def test_analyze_requires_input():
    with pytest.raises(food.AnalysisError):
        asyncio.run(food.analyze_meal(None, "  "))


def test_store_meal_and_status():
    db = sqlite3.connect(":memory:")
    db.row_factory = sqlite3.Row
    db.executescript("""
      CREATE TABLE meals(id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER, caption TEXT, meal_type TEXT,
        kcal REAL, protein_g REAL, carbs_g REAL, fat_g REAL, fiber_g REAL, confidence REAL, status TEXT, source TEXT, raw_json TEXT);
      CREATE TABLE meal_photos(id INTEGER PRIMARY KEY AUTOINCREMENT, meal_id INTEGER, idx INTEGER, mime TEXT, data BLOB);
      CREATE TABLE meal_items(id INTEGER PRIMARY KEY AUTOINCREMENT, meal_id INTEGER, name TEXT, grams REAL, kcal REAL,
        protein_g REAL, carbs_g REAL, fat_g REAL);""")
    mid = food.store_meal(db, food.validate(GOOD), photos=[_jpeg(), _jpeg()], caption="c", ts=1_700_000_000)
    row = db.execute("SELECT * FROM meals WHERE id=?", (mid,)).fetchone()
    assert row["status"] == "pending" and row["kcal"] == 458 and food.meal_photo_count(db, mid) == 2
    assert db.execute("SELECT COUNT(*) FROM meal_items WHERE meal_id=?", (mid,)).fetchone()[0] == 2
    assert food.meal_photo_count(db, mid) == 2
    assert food.set_status(db, mid, "confirmed") and not food.set_status(db, 999, "confirmed")
    with pytest.raises(ValueError):
        food.set_status(db, mid, "bogus")


def _mem_db():
    db = sqlite3.connect(":memory:")
    db.row_factory = sqlite3.Row
    db.executescript("""
      CREATE TABLE meals(id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER, caption TEXT, meal_type TEXT,
        kcal REAL, protein_g REAL, carbs_g REAL, fat_g REAL, fiber_g REAL, confidence REAL, status TEXT, source TEXT, raw_json TEXT);
      CREATE TABLE meal_photos(id INTEGER PRIMARY KEY AUTOINCREMENT, meal_id INTEGER, idx INTEGER, mime TEXT, data BLOB);
      CREATE TABLE meal_items(id INTEGER PRIMARY KEY AUTOINCREMENT, meal_id INTEGER, name TEXT, grams REAL, kcal REAL,
        protein_g REAL, carbs_g REAL, fat_g REAL);""")
    return db


def test_several_photos_go_in_one_request_and_prompt_says_same_session():
    out, calls = _analyze([json.dumps(GOOD)], image=[_jpeg(), _jpeg(), _jpeg()], caption="")
    user = calls[0]["messages"][1]["content"]
    assert sum(p["type"] == "image_url" for p in user) == 3 and "same eating session" in user[0]["text"]
    assert "never count the same food twice" in calls[0]["messages"][0]["content"]


def test_too_many_photos_rejected():
    with pytest.raises(food.AnalysisError):
        asyncio.run(food.analyze_meal([_jpeg(size=(10, 10))] * (food.MAX_PHOTOS + 1), ""))


def test_extend_pending_meal_reanalyses_all_photos():
    db = _mem_db()
    mid = food.store_meal(db, food.validate(GOOD), photos=[_jpeg()], caption="lunch", ts=1_700_000_000)
    bigger = json.loads(json.dumps(GOOD))
    bigger["items"].append({"name": "cola", "grams": 330, "kcal": 139, "protein_g": 0, "carbs_g": 35, "fat_g": 0})
    calls = []

    async def handler(request):
        calls.append(await request.json())
        return web.json_response({"choices": [{"message": {"content": json.dumps(bigger)}}]})

    async def go():
        app = web.Application()
        app.router.add_post("/v1/chat/completions", handler)
        async with TestServer(app) as srv:
            c = llm.LLM(base_url=str(srv.make_url("/v1")), model="m", api_key="k", timeout=5)
            return await food.extend_meal(db, mid, [_jpeg()], "plus a cola", llm=c)

    a = asyncio.run(go())
    user = calls[0]["messages"][1]["content"]
    assert sum(p["type"] == "image_url" for p in user) == 2 and "lunch plus a cola" in user[0]["text"]
    assert a["totals"]["kcal"] == 458 + 139 and food.meal_photo_count(db, mid) == 2
    row = db.execute("SELECT * FROM meals WHERE id=?", (mid,)).fetchone()
    assert row["kcal"] == 597 and row["caption"] == "lunch plus a cola"
    assert db.execute("SELECT COUNT(*) FROM meal_items WHERE meal_id=?", (mid,)).fetchone()[0] == 3


def test_cannot_extend_confirmed_or_missing_meal():
    db = _mem_db()
    mid = food.store_meal(db, food.validate(GOOD), photos=[_jpeg()], caption="")
    food.set_status(db, mid, "confirmed")
    for m in (mid, 999):
        with pytest.raises(food.AnalysisError):
            asyncio.run(food.extend_meal(db, m, [_jpeg()], ""))


def test_prepared_jpeg_is_not_reencoded_but_big_or_rotated_ones_are():
    small = _jpeg(size=(800, 600))
    assert food.prepare_image(small) == small  # idempotent: no generation loss
    big = food.prepare_image(_jpeg(size=(3000, 2000)))
    assert max(Image.open(io.BytesIO(big)).size) == food.MAX_SIDE and food.prepare_image(big) == big
    rotated = io.BytesIO()
    im = Image.new("RGB", (800, 400), (10, 200, 10))
    ex = im.getexif(); ex[0x0112] = 6
    im.save(rotated, "JPEG", exif=ex)
    assert Image.open(io.BytesIO(food.prepare_image(rotated.getvalue()))).size == (400, 800)


def test_photos_stored_as_blobs_and_retrievable():
    db = _mem_db()
    mid = food.store_meal(db, food.validate(GOOD), photos=[_jpeg(size=(900, 600))], caption="")
    mime, data = food.meal_photo(db, mid, 0)
    assert mime == "image/jpeg" and Image.open(io.BytesIO(data)).size == (900, 600)
    assert food.meal_photo(db, mid, 5) is None


def test_api_stores_photos_in_db_serves_them_and_extends(monkeypatch):
    from atomhealth import app as appmod

    seen = []

    async def fake_analyze(images, caption, llm=None):
        seen.append(len(images))
        return food.validate(GOOD)

    monkeypatch.setattr(food, "analyze_meal", fake_analyze)

    async def go():
        from aiohttp import FormData
        from aiohttp.test_utils import TestClient
        async with TestClient(TestServer(appmod.make_app(False, True))) as c:
            fd = FormData()
            for _ in range(2):
                fd.add_field("photo", _jpeg(size=(900, 600)), filename="a.jpg", content_type="image/jpeg")
            fd.add_field("caption", "lunch")
            r = await (await c.post("/api/food/analyze", data=fd)).json()
            mid = r["meal_id"]
            p0 = await c.get(f"/api/food/{mid}/photo/0")
            p2 = await c.get(f"/api/food/{mid}/photo/2")
            big = FormData()
            for _ in range(food.MAX_PHOTOS + 1):
                big.add_field("photo", _jpeg(size=(50, 50)), filename="a.jpg", content_type="image/jpeg")
            too_many = await c.post("/api/food/analyze", data=big)
            return mid, p0.status, p0.content_type, len(await p0.read()), p2.status, too_many.status

    mid, s0, ct, n, s2, many = asyncio.run(go())
    assert seen == [2] and s0 == 200 and ct == "image/jpeg" and n > 0 and s2 == 404 and many == 422
    assert food.meal_photo_count(appmod.db, mid) == 2


def test_meal_type_follows_the_clock_not_the_food():
    import time
    at = lambda h: time.mktime((2026, 11, 10, h, 30, 0, 0, 0, -1))
    assert [food.meal_type_for(at(h)) for h in (2, 4, 8, 11, 15, 16, 18, 21, 23)] == [
        "snack", "breakfast", "breakfast", "lunch", "lunch", "snack", "dinner", "dinner", "snack"]


def test_store_meal_overrides_model_meal_type(tmp_path):
    import sqlite3, time
    db = sqlite3.connect(":memory:")
    db.row_factory = sqlite3.Row
    db.executescript("""
      CREATE TABLE meals(id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER, caption TEXT, meal_type TEXT,
        kcal REAL, protein_g REAL, carbs_g REAL, fat_g REAL, fiber_g REAL, confidence REAL, status TEXT,
        source TEXT, raw_json TEXT);
      CREATE TABLE meal_items(id INTEGER PRIMARY KEY AUTOINCREMENT, meal_id INTEGER, name TEXT, grams REAL,
        kcal REAL, protein_g REAL, carbs_g REAL, fat_g REAL);
      CREATE TABLE meal_photos(id INTEGER PRIMARY KEY AUTOINCREMENT, meal_id INTEGER, idx INTEGER, mime TEXT, data BLOB);
    """)
    ts = int(time.mktime((2026, 11, 10, 19, 0, 0, 0, 0, -1)))
    mid = food.store_meal(db, food.validate({**GOOD, "meal_type": "breakfast"}), photos=None, caption="", ts=ts)
    assert db.execute("SELECT meal_type FROM meals WHERE id=?", (mid,)).fetchone()[0] == "dinner"
    assert food.delete_meal(db, mid) and not food.delete_meal(db, mid)
