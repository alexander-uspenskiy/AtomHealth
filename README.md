# AtomHealth

Local web app for the Raganet HG007-1 Bluetooth scale. The scale broadcasts its weight in
its BLE advertisement (no pairing); `atomhealth` listens, stores readings in SQLite (`data/weight.db`),
and serves a dashboard with estimated body composition, goals and statistics.

    .venv/bin/python -m atomhealth            # http://localhost:8765  (run from your own Terminal for Bluetooth access)
    .venv/bin/python -m atomhealth --lan      # also reachable by your phone (Health feed only)
    .venv/bin/python -m atomhealth --no-ble   # manual entry / testing

Close the scale's phone app (it can hog the scale) and step on the scale: readings are saved once the number holds steady for 3 s.

Set height / age / sex / targets in Settings. With no targets set, the optimal weight (BMI 22) and an age/sex body-fat range are used.
Fat %, lean/muscle mass, water and BMR are formula estimates (Deurenberg, Mifflin-St Jeor), not measurements.

Apple Health: Settings tab shows the iOS Shortcut recipe (feed: `/api/health/pending?token=...`).

## Layout

    src/atomhealth/   app.py (server), bodycomp.py (formulas), static/ (dashboard UI)
    scripts/          scale.py BLE debugging tool (scan, watch, listen), probe.py
    data/             weight.db, weights.csv (git-ignored); data/debug/ captured BLE logs
    tests/            pytest smoke tests
    .env              local settings (see .env.example)

Setup: `python -m venv .venv && .venv/bin/pip install -e '.[dev]'`; tests: `.venv/bin/python -m pytest`.
Override the data location with `ATOMHEALTH_DATA_DIR`.
