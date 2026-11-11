"""Settings from environment variables, with a minimal .env loader (no extra dependency)."""
import os
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]


def load_dotenv(path=None):
    """Load KEY=VALUE lines from .env into os.environ without overriding existing variables."""
    path = Path(path) if path else PROJECT_ROOT / ".env"
    if not path.is_file():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        os.environ.setdefault(k.strip(), v.strip().strip("'\""))


load_dotenv()


def llm_settings():
    return {
        "base_url": os.environ.get("LLM_BASE_URL", "http://127.0.0.1:8082/v1").rstrip("/"),
        "model": os.environ.get("LLM_MODEL", "qwen3.8-27b-uncensored"),
        "api_key": os.environ.get("LLM_API_KEY", "local"),
        "timeout": float(os.environ.get("LLM_TIMEOUT", "180")),
    }
