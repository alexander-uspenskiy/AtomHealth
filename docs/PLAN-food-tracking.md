# Plan: Food photo analysis service + Telegram bot

## Goal
Send a photo of a meal to a Telegram bot → local Qwen (vision) identifies the food and estimates
portions/calories/macros → result is stored → the bot and dashboard give recommendations to tweak
the diet plan, using the existing weight/body-comp/goal data.

## Fit with the existing app
- AtomHealth is a single aiohttp process (`src/atomhealth/app.py`) with SQLite (`data/weight.db`),
  profile/goal in `kv`, formulas in `bodycomp.py` (BMR, Nutrition tab).
- `.env.example` already defines a local Qwen via llama-server (OpenAI-compatible, `LLM_BASE_URL`).
- So: **extend the same service** (new modules + REST endpoints), and run the bot as an asyncio task
  inside it (long polling → no public URL/webhook needed, data stays on the Mac).

## Architecture
```
Telegram  ⇄  bot (aiogram or raw aiohttp long-polling)
                 │ photo bytes + caption
                 ▼
          atomhealth.food  ── vision call ──►  llama-server (Qwen, OpenAI API)
                 │  validated JSON
                 ▼
          SQLite: meals, meal_items  ──►  /api/food/*  ──►  dashboard "Food" tab
                 ▲
          advisor (daily/weekly) ◄── weight trend, goal, BMR/TDEE from bodycomp.py
```

New modules under `src/atomhealth/`:
- `llm.py` – thin OpenAI-compatible client (image as base64 data URL, JSON-schema/`response_format`, retries, timeout).
- `food.py` – analysis pipeline, prompts, schema validation, macro sanity checks.
- `advisor.py` – daily/weekly summaries and diet-tweak recommendations.
- `bot.py` – Telegram handlers (long polling), user allow-list.
- DB migrations inside `app.py`/new `db.py` (same `CREATE TABLE IF NOT EXISTS` style).

## Data model
- `meals(id, ts, photo_path, caption, meal_type, kcal, protein_g, carbs_g, fat_g, fiber_g, confidence, status, raw_json, source)`
- `meal_items(id, meal_id, name, grams, kcal, protein_g, carbs_g, fat_g)`
- `food_goals` via `kv` (daily kcal target, protein target) – defaulting from Nutrition tab logic.
- Photos saved to `data/meals/YYYY/MM/<id>.jpg` (downscaled to ~1024px before sending to the model).

## Analysis pipeline (accuracy is the hard part)
1. Telegram photo → download largest size → resize/EXIF-rotate → store.
2. Qwen vision prompt returns **strict JSON**: items[{name, estimated_grams, kcal, protein, carbs, fat}], confidence, notes.
   Caption is passed as context ("200 g rice, homemade").
3. Validate: schema check, kcal ≈ 4P+4C+9F (within tolerance, else recompute from macros), sane gram ranges.
4. Reply with a summary + inline buttons: ✅ Save · ✏️ Fix (edit item/grams in chat) · 🗑 Discard.
   Nothing is stored as final until confirmed (or auto-confirm toggle).
5. Optional later: small local food-reference table (per-100 g values) to ground the model's numbers instead of trusting its memory.

Honest limits: calories from a photo are ±20–30%; the confirm/correct step and the caption hints are what keep the log trustworthy.

## Recommendations engine
- **Per meal:** one-line verdict vs. remaining daily budget and protein target.
- **Daily (evening, scheduled):** totals vs. target, what's off, one concrete tweak for tomorrow.
- **Weekly:** compare avg intake with weight trend (7/14-day slope from `readings`) → implied real TDEE → suggest target adjustment (e.g. "−150 kcal/day", "raise protein to 130 g"). The LLM writes the wording; numbers come from code, not the model.
- Guardrails: no targets below safe minimum (BMR-based floor), disclaimer that it's not medical advice.

## Telegram bot
- Commands: `/start` (link chat), `/today`, `/week`, `/goal <kcal>`, `/undo`, `/weight` (latest reading), `/help`.
- Photo (with optional caption) → analysis flow above. Text-only message ("2 eggs and toast") → same pipeline without image.
- Security: bot token in `.env` (`TELEGRAM_BOT_TOKEN`), **allow-list of chat IDs** (`TELEGRAM_ALLOWED_IDS`); everything else ignored. Single-user by design.
- Needs the Mac/server running to respond; messages queue on Telegram's side while offline (long polling resumes).

## Dashboard
New **Food** tab: today's ring (kcal/macros vs target), meal timeline with photos, 7/30-day intake chart overlaid on the weight trend, recommendation card, edit/delete.

## Milestones
1. **Foundation** – `llm.py`, DB tables, `.env` config, tests with a mocked LLM.
2. **Analysis** – `food.py` + CLI/`POST /api/food/analyze` test endpoint; try on ~15 real photos, tune prompt.
3. **Bot MVP** – photo → analysis → confirm → store; allow-list; `/today`.
4. **Advisor** – per-meal verdict, daily summary, weekly TDEE-based tweak, scheduled messages.
5. **Dashboard** Food tab + README/screenshots.
6. **Hardening** – error handling, retry/queue if Qwen is down, backups, run-as-service (launchd) docs.

## Decisions needed / risks
1. **Does the local Qwen support vision?** `qwen3.8-27b-uncensored` on llama-server only sees images if started with a multimodal projector (`--mmproj`). Must verify first (quick probe in step 1); otherwise load a Qwen-VL model alongside.
2. **Hosting:** bot runs on this Mac (simple, private) vs. always-on box/VPS (bot always replies; Qwen must be reachable, e.g. via Tailscale). Recommend Mac first.
3. **Telegram bot token** from @BotFather and your Telegram user ID (you provide; goes in `.env`, never committed).
4. **Auto-save vs confirm** – recommend confirm-by-default.
5. **Privacy:** photos/meals stay local; only Telegram transports the image.
6. **Dependencies:** `aiogram` (or none, raw HTTP) – recommend `aiogram` 3.x for polling/FSM edit flow.
