"""Plain-text understanding for the Telegram bot: what does a free-form message want?

The model only picks an intent (and a meal number); the bot's normal code does the work, so every
command is also reachable in plain words. If the model is unreachable the bot falls back to `fallback`.
"""
import time

from .llm import LLM, LLMError, extract_json

INTENTS = ("log", "ask", "today", "history", "advice", "week", "weight", "delete", "edit", "undo", "help")

SYSTEM = """You route messages sent to a personal nutrition bot. Reply with ONE JSON object and nothing else:
{"intent": "<one of: log, ask, today, history, advice, week, weight, delete, edit, undo, help>",
 "meal_id": <number or null>, "text": "<string or empty>"}

Intents:
- log: the user describes food they ate or are eating ("2 eggs and toast", "had a salad for lunch"), or adds detail to
  the meal they are logging right now ("it was 300 g").
- ask: a question or request for advice, ideas or planning ("what should I eat today?", "can I have pasta?").
- today: wants to see today's meals, calories, totals or statistics so far.
- history: wants the list of recent meals (last 12 hours).
- advice: wants today's coaching advice / summary written for them.
- week: wants the weekly review.
- weight: asks for their latest weight.
- delete: wants a specific logged meal removed. Set meal_id to the id from the recent meals list that matches
  what they described (a dish name, a time, "the last one"). null if you cannot tell which.
- edit: says a logged meal was recorded wrongly and gives the correction ("the potato was 150 g with butter").
  Set meal_id as for delete and "text" to the corrected description of that meal, in full.
- undo: wants the last meal removed ("undo", "remove the last one").
- help: asks what the bot can do.
Only use meal ids that appear in the list. When unsure between log and ask, prefer ask if there is a question."""


def _prompt(text, meals, open_session):
    lines = [f"recent meals (id, time, dishes, kcal): " + ("; ".join(
        f"#{m['id']} {m['time']} {m['dishes']} {m['kcal']} kcal" for m in meals) or "none")]
    if open_session:
        lines.append("The user is in the middle of logging a meal right now.")
    lines.append(f"message: {text}")
    return "\n".join(lines)


def fallback(text):
    """Offline guess: a question goes to the coach, a bare keyword runs that command, the rest is a meal."""
    t = text.strip().lower().strip("!. ")
    if t in ("today", "history", "advice", "week", "weight", "undo", "help"):
        return {"intent": t, "meal_id": None, "text": ""}
    if "?" in t or t.startswith(_QUESTION_START):
        return {"intent": "ask", "meal_id": None, "text": ""}
    return {"intent": "log", "meal_id": None, "text": ""}


_QUESTION_START = tuple(w + " " for w in (
    "what", "which", "who", "how", "why", "when", "where", "can", "could", "should", "would", "will", "is", "are",
    "am", "do", "does", "did", "tell me", "give me", "suggest", "recommend", "advise", "help me",
    "что", "как", "почему", "сколько", "можно", "стоит", "посоветуй", "подскажи", "какой", "какие", "когда"))


async def classify(text, meals, open_session=False, llm=None):
    """{"intent", "meal_id", "text"}; raises LLMError when the model is unreachable or answers nonsense."""
    llm = llm or LLM()
    raw = extract_json(await llm.chat([{"role": "system", "content": SYSTEM},
                                       {"role": "user", "content": _prompt(text, meals, open_session)}],
                                      max_tokens=200, temperature=0.0))
    if not isinstance(raw, dict) or raw.get("intent") not in INTENTS:
        raise LLMError(f"unusable routing answer: {raw!r}"[:200])
    ids = {m["id"] for m in meals}
    mid = raw.get("meal_id")
    mid = int(mid) if isinstance(mid, (int, float)) and int(mid) in ids else None
    return {"intent": raw["intent"], "meal_id": mid, "text": str(raw.get("text") or "")[:500]}
