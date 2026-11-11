from atomhealth import app, bodycomp


def test_package_paths():
    assert app.STATIC_DIR.joinpath("index.html").is_file()
    assert app.DATA_DIR.is_dir()


def test_bodycomp_importable():
    assert hasattr(bodycomp, "compute") and hasattr(bodycomp, "healthy_range")
