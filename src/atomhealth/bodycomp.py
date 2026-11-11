"""Body-composition estimates from weight + profile.

These are population-formula ESTIMATES, not measurements. The scale's raw
impedance is stored but not used (its vendor formula is proprietary).
"""


def compute(weight, profile):
    h = float(profile.get("height_cm") or 0)
    age = float(profile.get("age") or 0)
    male = (profile.get("sex") or "male") == "male"
    if not weight or h <= 0:
        return {}
    m = h / 100
    bmi = weight / (m * m)
    # Deurenberg et al. (1991) body-fat estimate from BMI, age and sex.
    bf = 1.20 * bmi + 0.23 * age - 10.8 * (1 if male else 0) - 5.4
    bf = max(3.0, min(60.0, bf))
    fat = weight * bf / 100
    lean = weight - fat
    water = 0.73 * lean / weight * 100  # lean tissue is ~73% water
    muscle = lean * (0.52 if male else 0.47)  # rough skeletal-muscle share of lean mass
    bmr = 10 * weight + 6.25 * h - 5 * age + (5 if male else -161)  # Mifflin-St Jeor
    return {
        "ffmi": round(lean / (m * m), 1),            # fat-free mass index
        "nffmi": round(lean / (m * m) + 6.1 * (1.8 - m), 1),  # height-normalised (Kouri 1995)
        "fmi": round(fat / (m * m), 1),              # fat mass index
        "bsa": round((h * weight / 3600) ** 0.5, 2),  # body surface area, Mosteller
        "tbw_kg": round(water * weight / 100, 1),
        "bmi": round(bmi, 1),
        "fat_pct": round(bf, 1),
        "fat_kg": round(fat, 1),
        "lean_kg": round(lean, 1),
        "muscle_kg": round(muscle, 1),
        "water_pct": round(water, 1),
        "bmr": round(bmr),
    }


def healthy_range(profile):
    h = float(profile.get("height_cm") or 0) / 100
    if h <= 0:
        return None
    return [round(18.5 * h * h, 1), round(24.9 * h * h, 1)]


def optimal(profile):
    """Optimal weight (BMI 22, mid healthy range) and age/sex body-fat range
    (Gallagher et al. 2000 healthy ranges)."""
    h = float(profile.get("height_cm") or 0) / 100
    age = float(profile.get("age") or 0)
    male = (profile.get("sex") or "male") == "male"
    out = {"weight": round(22 * h * h, 1) if h > 0 else None}
    if male:
        rng = (8, 19) if age < 40 else (11, 21) if age < 60 else (13, 24)
    else:
        rng = (21, 32) if age < 40 else (23, 33) if age < 60 else (24, 35)
    out["fat_pct_range"] = list(rng)
    out["fat_pct"] = round(sum(rng) / 2, 1)
    return out


ACTIVITY = [("Sedentary (desk job, little exercise)", 1.2), ("Light (1-3 workouts/week)", 1.375),
            ("Moderate (3-5 workouts/week)", 1.55), ("Very active (6-7 workouts/week)", 1.725),
            ("Extreme (physical job + training)", 1.9)]


def reference(profile):
    """Reference ranges / zones used by the dashboard gauges (single source of truth)."""
    h = float(profile.get("height_cm") or 0)
    male = (profile.get("sex") or "male") == "male"
    inch = h / 2.54 - 60  # inches over 5 ft
    if male:
        ideal = {"Devine (1974)": 50 + 2.3 * inch, "Robinson (1983)": 52 + 1.9 * inch,
                 "Miller (1983)": 56.2 + 1.41 * inch, "Hamwi (1964)": 48 + 2.7 * inch}
        fat = [("Essential", 2, 6, "z1"), ("Athletic", 6, 14, "z2"), ("Fitness", 14, 18, "z3"),
               ("Average", 18, 25, "z4"), ("High", 25, 45, "z6")]
        ffmi = [("Below average", 10, 18, "z1"), ("Average", 18, 20, "z3"), ("Above average", 20, 22, "z2"),
                ("Excellent", 22, 25, "z2"), ("Very high", 25, 32, "z4")]
        water = [50, 65]
    else:
        ideal = {"Devine (1974)": 45.5 + 2.3 * inch, "Robinson (1983)": 49 + 1.7 * inch,
                 "Miller (1983)": 53.1 + 1.36 * inch, "Hamwi (1964)": 45.4 + 2.27 * inch}
        fat = [("Essential", 10, 14, "z1"), ("Athletic", 14, 21, "z2"), ("Fitness", 21, 25, "z3"),
               ("Average", 25, 32, "z4"), ("High", 32, 50, "z6")]
        ffmi = [("Below average", 8, 14, "z1"), ("Average", 14, 16, "z3"), ("Above average", 16, 18, "z2"),
                ("Excellent", 18, 20, "z2"), ("Very high", 20, 28, "z4")]
        water = [45, 60]
    z = lambda rows: [{"label": a, "from": b, "to": c, "cls": d} for a, b, c, d in rows]
    return {
        "bmi_zones": z([("Underweight", 15, 18.5, "z1"), ("Healthy", 18.5, 25, "z2"),
                        ("Overweight", 25, 30, "z4"), ("Obese I", 30, 35, "z5"), ("Obese II+", 35, 40, "z6")]),
        "fat_zones": z(fat), "ffmi_zones": z(ffmi), "water_range": water,
        "ideal": {k: round(v, 1) for k, v in ideal.items()} if h else {},
        "activity": [{"label": a, "factor": f} for a, f in ACTIVITY],
    }
