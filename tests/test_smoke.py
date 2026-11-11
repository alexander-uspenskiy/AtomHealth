from atomhealth import app, bodycomp


def test_package_paths():
    assert app.STATIC_DIR.joinpath("index.html").is_file()
    assert app.DATA_DIR.is_dir()


def test_bodycomp_importable():
    assert hasattr(bodycomp, "compute") and hasattr(bodycomp, "healthy_range")


def _p(**kw):
    return {"height_cm": 175, "age": 35, "sex": "male", **kw}


def test_nutrition_maintenance_matches_formula():
    n = bodycomp.nutrition(_p(diet_goal="maintain", activity=1.55), 70)
    bmr = 10 * 70 + 6.25 * 175 - 5 * 35 + 5
    assert n["bmr"] == round(bmr) and n["maintenance"] == round(bmr * 1.55) and n["kcal"] == n["maintenance"]
    assert sum(m["pct"] for m in n["macros"]) in (99, 100, 101)


def test_nutrition_auto_goal_and_deficit():
    n = bodycomp.nutrition(_p(target_weight=75), 90)  # auto -> lose, 0.5 kg/week = 550 kcal
    assert n["goal"] == "lose" and n["adjust"] == -550 and n["weeks"] == 30
    assert bodycomp.nutrition(_p(target_weight=75), 60)["goal"] == "gain"


def test_nutrition_deficit_floor():
    n = bodycomp.nutrition(_p(sex="female", age=60, height_cm=155, activity=1.2, diet_goal="lose", diet_pace=1), 80)
    assert n["kcal"] >= 1200 and n["warnings"]


def test_nutrition_needs_data():
    assert bodycomp.nutrition(_p(), None) == {}


def test_meal_history_lists_meals_with_photos_and_skips_discarded():
    from atomhealth import food
    db = app.db
    db.execute("DELETE FROM meals")
    a = {"is_food": True, "meal_type": "lunch", "confidence": 0.8, "notes": "", "adjusted": [],
         "items": [{"name": "rice", "grams": 150, "kcal": 200, "protein_g": 4, "carbs_g": 44, "fat_g": 1, "fiber_g": 1}],
         "totals": {"kcal": 200, "protein_g": 4, "carbs_g": 44, "fat_g": 1, "fiber_g": 1}}
    keep = food.store_meal(db, a, photos=None, caption="homemade")
    gone = food.store_meal(db, a, photos=None, caption="")
    food.set_status(db, gone, "discarded")
    m = app.meal_history()
    assert [x["id"] for x in m] == [keep]
    assert m[0]["items"][0]["name"] == "rice" and m[0]["photos"] == 0 and m[0]["caption"] == "homemade"
