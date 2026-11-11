import os
import tempfile

# Tests must never touch the real data/weight.db: point the app at a throwaway directory before it is imported.
os.environ["ATOMHEALTH_DATA_DIR"] = tempfile.mkdtemp(prefix="atomhealth-test-")
os.environ.pop("WEIGHT_DB", None)
os.environ["TELEGRAM_BOT_TOKEN"] = ""      # a real token in .env must never start a bot during tests
os.environ["TELEGRAM_ALLOWED_IDS"] = ""
