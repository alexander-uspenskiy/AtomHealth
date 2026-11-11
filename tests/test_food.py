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


def test_store_meal_and_status(tmp_path):
    db = sqlite3.connect(":memory:")
    db.row_factory = sqlite3.Row
    db.executescript("""
      CREATE TABLE meals(id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER, photo_path TEXT, caption TEXT, meal_type TEXT,
        kcal REAL, protein_g REAL, carbs_g REAL, fat_g REAL, fiber_g REAL, confidence REAL, status TEXT, source TEXT, raw_json TEXT);
      CREATE TABLE meal_items(id INTEGER PRIMARY KEY AUTOINCREMENT, meal_id INTEGER, name TEXT, grams REAL, kcal REAL,
        protein_g REAL, carbs_g REAL, fat_g REAL);""")
    mid = food.store_meal(db, food.validate(GOOD), photo=_jpeg(), caption="c", photos_dir=tmp_path, ts=1_700_000_000)
    row = db.execute("SELECT * FROM meals WHERE id=?", (mid,)).fetchone()
    assert row["status"] == "pending" and row["kcal"] == 458 and (tmp_path / row["photo_path"]).is_file()
    assert db.execute("SELECT COUNT(*) FROM meal_items WHERE meal_id=?", (mid,)).fetchone()[0] == 2
    assert food.set_status(db, mid, "confirmed") and not food.set_status(db, 999, "confirmed")
    with pytest.raises(ValueError):
        food.set_status(db, mid, "bogus")
