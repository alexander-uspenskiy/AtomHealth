# Architecture: Apple Health sync via Cloudflare relay

Status: relay **built and deployed** (`relay/`); Mac-side `sync.py`, `relay.py` and `/api/sync/v1` **built and tested** (107 tests green, end-to-end run against a local relay); the iOS app is **not built yet**.
Product plan, requirements and budget: [PLAN-apple-health-app.md](PLAN-apple-health-app.md). Security: [SECURITY-sync.md](SECURITY-sync.md).

## 1. System overview

```
 iPhone (SwiftUI app)                 Cloudflare account (free tier)              Mac / Pi (AtomHealth service)
 ┌──────────────────────┐   HTTPS     ┌─────────────────────────────┐   HTTPS    ┌─────────────────────────────┐
 │ HealthKit ⇄ SyncEngine│ ──push───► │ Worker  atomhealth-relay    │ ◄──pull─── │ relay.py (asyncio task)     │
 │ encrypt / decrypt     │ ◄──pull─── │  /v1/{pair,push,pull,ack}   │ ───push──► │ encrypt / decrypt           │
 │ key: iOS Keychain     │            │ D1: devices, changes        │            │ SQLite = source of truth    │
 └──────────────────────┘             │ (ciphertext only)           │            │ scale BLE, Telegram, advisor│
                                      └─────────────────────────────┘            └─────────────────────────────┘
```

- **Relay = mailbox.** Append-only log of encrypted records. It cannot read, merge or interpret data.
- **Both ends keep full copies.** The relay holds changes in transit only; wiping it loses nothing.
- **Phone and Mac never need to be online together.** Each pulls whatever the other pushed since its last cursor.
- **Optional fast path:** direct LAN/Tailscale to the Mac when reachable (same payloads, different transport).

## 2. Deployed resources

| Item | Value |
|---|---|
| Cloudflare account | the owner's personal account (Google sign-in) |
| Worker name / URL | `atomhealth-relay` → `https://atomhealth-relay.atomhealth.workers.dev` |
| D1 database | `atomhealth-relay`, id `9729bb26-aaa1-4ca0-a609-d58d86891fda` (region WNAM) |
| Cron | `17 3 * * *` UTC — cleanup |
| Secret | `ADMIN_CODE` (Worker secret). Local copy: `relay/.admin-code` (gitignored, mode 600) |
| Source | `relay/src/index.ts`, `relay/migrations/0001_init.sql`, `relay/test/relay.test.ts` |
| Tooling | wrangler 4.x, vitest 4 + `@cloudflare/vitest-plugin` (the old `vitest-pool-workers` is deprecated) |

The database id and Worker URL are identifiers, not secrets.

## 3. Relay API (`/v1`)

All responses are JSON, `cache-control: no-store`, with HSTS/nosniff. Plain HTTP is rejected (403).

| Endpoint | Auth | Request | Response |
|---|---|---|---|
| `GET /health` | none | – | `{ok:true}` |
| `POST /pair` | `x-admin-code` | `{name}` | 201 `{device_id, token}`; 409 at 5 active devices |
| `DELETE /devices/:id` | `x-admin-code` | – | `{revoked}` |
| `POST /push` | `Bearer <device_id>.<secret>` | `{records:[{record_id, nonce, ciphertext}]}` 1–50 | `{seqs:[{record_id, seq}]}` — idempotent per `(device, record_id)` |
| `GET /pull?since=&limit=` | Bearer | limit ≤ 200, response ≤ ~4 MB | `{records:[…other devices only…], next_seq, has_more}` |
| `POST /ack` | Bearer | `{cursor}` | `{ok:true}` |

Validation: `record_id` `[A-Za-z0-9_-]{8,64}`; `nonce` base64 ≤ 64 chars; `ciphertext` base64 ≤ ~64 KB; request body ≤ 1 MB.
`next_seq` advances past the caller's own rows so cursors never stall.

### Data model (D1)
```sql
devices(device_id PK, name, token_hash, cursor, created_at, last_seen, revoked)
changes(seq INTEGER PK AUTOINCREMENT, device_id, record_id, nonce, ciphertext, created_at,
        UNIQUE(device_id, record_id))
```
Only the SHA-256 of the device secret is stored. `last_seen` is written at most every 5 minutes.

### Retention
Daily cron deletes rows with `seq ≤ min(cursor)` over active devices (when ≥ 2 exist) **or** older than 30 days. A device that never acks therefore holds data for at most 30 days.

## 4. Record envelope (client-side, to be implemented)

The relay only sees `record_id`, `nonce`, `ciphertext`. Everything meaningful is inside the ciphertext:

```json
{ "v": 1, "type": "weight|meal|activity_day|workout|profile", "op": "upsert|delete",
  "id": "<stable entity id>", "version": 7, "updated_at": 1763150000, "tz": "+01:00", "data": { … } }
```

- **Cipher:** ChaCha20-Poly1305 (CryptoKit on iOS, `cryptography` in Python), 256-bit key, random 96-bit nonce per record.
- **AAD (required):** `"atomhealth-v1|" + device_id + "|" + record_id`, so the relay cannot swap ciphertexts between records or devices undetected.
- **Every change is a new `record_id`** (the relay never overwrites). Edits and deletes are new records with a higher `version` for the same entity `id`.
- **Merge:** clients apply last-writer-wins on `(version, updated_at)`; dedupe rules from the plan §5.4.
- **Replay:** applying an old record is harmless because older `version`s lose.

## 5. Pairing & key distribution

1. Owner runs `pair` using the admin code (CLI or a small helper) → `device_id` + token per device.
2. The phone generates the 256-bit data key on first launch (Keychain, `AfterFirstUnlockThisDeviceOnly`).
3. The Mac shows a **one-time QR** containing: relay URL, the Mac's device token, and — only when pairing the phone — the data key. (Preferred: the phone generates the key and shows the QR; the Mac scans/imports it, so the key is created on the device that holds HealthKit.)
4. The Mac stores key + token in macOS Keychain (not `.env`).
5. Revocation: `DELETE /v1/devices/:id`. Key rotation = re-pair and re-upload (relay data is disposable).

## 6. Mac-side implementation (built)

| File | Role |
|---|---|
| `src/atomhealth/sync.py` | Sync core: schema migration, outbox triggers, `collect` (outbound), `apply_envelope`/`apply_batch` (inbound merge), `status` |
| `src/atomhealth/relay.py` | `RelayAgent` (pull → decrypt → merge → collect → encrypt → push), `RelayClient`, ChaCha20-Poly1305 helpers with AAD, `SecretStore` (Keychain/env), CLI |
| `src/atomhealth/app.py` | Calls `sync.migrate(db)` at start; `/api/sync/v1/{changes,push,status,config}`; starts the agent if paired; stops it on shutdown |
| `tests/test_sync.py`, `tests/test_relay.py` | 31 tests: triggers, coalescing, dedupe, LWW/tombstones, validation, API auth, crypto tamper cases, agent cycles against an in-process fake relay |

### 6.1 Capturing local changes (no code changes in other modules)
SQLite **triggers** on `readings`, `meals` and `meal_items` append `(type, sync_id)` to `sync_outbox`, so the dashboard, Telegram bot and CSV importer are all covered. Every reading/meal gets a stable random `sync_id` (backfilled on migration; existing data is queued once for the first sync).
The outbox is only a dirty marker: the payload is built from the **current row** at send time, so many edits collapse into one record. Writes made while applying remote changes set `sync_flags.applying=1`, which silences the triggers (no echo).

### 6.2 What is sent and received
| Direction | Type | Rule |
|---|---|---|
| Mac → phone | `weight` | scale/manual readings (never rows that came from Health) |
| Mac → phone | `meal` | **confirmed** meals only, with items; a meal that becomes pending/discarded/deleted is sent as `delete` (only if an upsert was sent earlier) |
| Phone → Mac | `weight` | creates a `readings` row with `source='applehealth'`, or **merges** into an existing scale/manual reading within ±120 s and ±0.1 kg (adds `fat_pct_m`/`lean_kg_m`, keeps the scale row, records a `sync_links` row) |
| Phone → Mac | `activity_day` | `activity_days(day, active_kcal, basal_kcal, steps)` |
| Phone → Mac | `nutrition_day` | `nutrition_days(...)` — daily totals logged by **other** apps, aggregated on the phone. Deliberately **not** inserted into `meals`, so it can never double-count with Telegram/photo meals |
| Phone → Mac | `workout` | `workouts(sync_id, start_ts, end_ts, type, kcal, distance_m)` |

Meals are outbound-only; inbound `meal` envelopes are rejected as invalid.

### 6.6 Phone chat (the app's Chat tab)
The Chat tab is the Telegram bot's logic served over this same relay: `phonechat.PhoneApi` stands in for the Telegram API, so commands, plain-words routing, meal analysis, albums, Save/Discard buttons, in-place message edits and `/undo` work on the phone without a second copy of the logic. Meals created there are tagged `source='phone'`. The phone's chat is a second `TelegramBot` instance (offset/ids kept under `pc_` kv keys; no daily summary, Telegram already sends it). Contract (also in the `phonechat.py` docstring):

| Direction | Type / id | Payload |
|---|---|---|
| phone → Mac | `chat_in` `t-<uuid>` | `{kind:"text", text}` a message or `/command` |
| phone → Mac | `chat_in` `p-<photo>-<i>` | `{kind:"photo", photo_id, idx, n, b64}` one chunk (≤ 40 KB of JPEG) |
| phone → Mac | `chat_in` `m-<uuid>` | `{kind:"message", text, photos:[photo_id…]}` sent after its chunks; >1 photo = an album |
| phone → Mac | `chat_in` `c-<uuid>` | `{kind:"callback", data, msg_id}` a tap on an inline button |
| phone → Mac | `chat_in` `g-<uuid>` | `{kind:"ping"}` "are you there?" (on opening the chat, then every ~40 s; every 5 min while unanswered) |
| Mac → phone | `chat_out` `presence` | `{ts, ai}` the answer to a ping; `ai` = AI backend reachable (probed every 60 s; null = unknown) |
| Mac → phone | `chat_out` `m<n>` | `{mid, text (Telegram-HTML subset), buttons:[[{text,data}]], ts, edited?}`; same id + higher version = edit |
| Mac → phone | `chat_out` `typing` / `toast` | `{typing_until}` / `{toast}` ephemeral |

- **Photos are resized on the phone** (`PhotoPrep`): longest side ≤ 1280 px, JPEG ≤ ~300 KB (quality 0.8 → 0.5, then smaller), EXIF rotation applied, **all metadata (GPS, camera, time) dropped**, never upscaled, transparent PNGs flattened on white. A 4 MB camera shot becomes ~150–300 KB = 4–8 chunks. The relay's record cap (~64 KB ciphertext) is why photos travel as chunks; the Mac reassembles by `photo_id`, drops incomplete photos after 15 min, and answers "a photo did not arrive completely" if one is missing. The relay keeps batch order, so chunks always precede their `message`.
- **Header status** (`ChatStatus.derive`, unit-tested): *No connection* (relay unreachable) · *Checking your Mac…* · *Mac not responding* (no answer 25 s after a ping or message; the explanation line says it may be asleep) · *Waiting for the answer…* · *Working…* (bot typing) · *Online* / *Online · AI offline* (commands work, meal photos and coaching will fail). Pings add ≤ ~1.4 k requests/day if the tab stays open all day. The status depends on the clock, so the header redraws on a 2 s timer (SwiftUI does not redraw when nothing observable changes, and a dead Mac sends nothing).
- **Latency:** the Mac polls the relay every 8 s (chat-only cycles; the full health/dashboard cycle stays on its 5 min timer) and pushes bot replies at once. The app polls every 4 s while the Chat tab is open (1.5 s while a reply is pending) and not at all in the background; there are no push notifications on a free Personal Team, so replies appear when the app is opened.
- **Not kept on the Mac:** chat history lives on the phone (400 messages, photos in the app's protected storage). Bot replies queued while the relay is unreachable are retried from memory and lost if the Mac service restarts before the relay comes back.

## 8a. Chat load on the free tier (estimates, Cloudflare limits checked 2026-11-15)
Workers Free: 100,000 requests/day, **10 ms CPU per request**; D1 Free: 5 M rows read, 100 k rows written (index writes count), 5 GB.

| Resource | Chat adds | Share of limit |
|---|---|---|
| Requests | Mac idle poll 10.8 k/day + phone open 4 s: up to 21.6 k/day + bursts ≈ 1 k | ≈ 15 % typical, ≈ 33 % if the tab is left open all day |
| D1 rows written | heavy day ≈ 330 records × 3 (table + 2 indexes) + acks ≈ 1.3 k | ≈ 1.3 % |
| D1 rows read | an idle poll reads 1 row (device lookup) | ≈ 0.2 % |
| Storage | ~300 KB per photo, deleted after both devices ack, 30 days at most | negligible |
| CPU per request | **not measured.** Photo records are ~70 KB each, so pushes are capped at ~300 KB per request and the Mac pulls 20 records per page (≤ 1.4 MB) to stay far from 10 ms. Check CPU time in the Workers dashboard after the first photo; fallback: smaller photos or Workers Paid ($5/mo) | open |

### 6.3 Versions, conflicts, deletes
Per entity, `sync_versions(type, sync_id, version, live)` stores the last version. Outbound version = `max(now_ms, previous+1)`, persisted only after delivery succeeded (`mark_sent`), so a failed push is simply retried. Inbound envelopes with `version <= stored` are ignored (**last-writer-wins**); a delete stores a tombstone so an older upsert cannot resurrect the entity. Deleting a Health sample that was *merged* into a scale reading only removes the link.

### 6.4 Relay agent behaviour
- One cycle = pull pages (100) → decrypt each record (bad/forged/wrong-key records are counted and skipped, never block the cursor) → `apply_batch` → persist `relay_cursor` → `ack`; then collect (50 per batch) → encrypt with a fresh `record_id` → push → `mark_sent` → persist `relay_pushed_seq`. State advances **only after** the other side accepted.
- Loop: every 5 min, sooner (≤10 s) when new local changes appear, exponential back-off up to 15 min on errors; errors never kill the task.
- Starts automatically with the service when paired (`kv relay` + Keychain token + key); `--no-relay` is not needed because unpaired = inert.
- Relay URL must be `https://` (client-side check; `http://localhost` allowed for development).

### 6.5 Setup (CLI)
```bash
.venv/bin/pip install -e '.[dev]'                       # now includes cryptography + keyring
export RELAY_ADMIN_CODE="$(cat relay/.admin-code)"      # or use --admin-code-file relay/.admin-code
.venv/bin/python -m atomhealth.relay pair --url https://atomhealth-relay.atomhealth.workers.dev --name mac
.venv/bin/python -m atomhealth.relay keygen             # or import-key if the phone created it
.venv/bin/python -m atomhealth.relay status             # cursors, pending count, last error
.venv/bin/python -m atomhealth.relay sync               # one cycle now
```
`pair` stores the device token in the macOS Keychain and never prints it. `export-key` prints the data key (use only for pairing the phone). Headless alternative: `RELAY_TOKEN` / `RELAY_KEY` env vars.

### 6.6 Direct (LAN/Tailscale) API — same core, plaintext envelopes
| Endpoint | Description |
|---|---|
| `GET /api/sync/v1/changes?since=&limit=` | outbound envelopes (deletes always included), `next_seq`, `has_more` |
| `POST /api/sync/v1/push` `{items:[…]}` (≤ 500) | inbound envelopes → `{applied, merged, stale, invalid}` |
| `GET /api/sync/v1/status` | counts, recent sync log, relay agent state |
| `GET /api/sync/v1/config` | envelope version, types, units |

Auth: `Authorization: Bearer <health token>` (preferred) or `?token=`; constant-time comparison. Use only over trusted networks/TLS.

## 6b. Still to build

| Component | Description | Plan phase |
|---|---|---|
| Pairing UI | Settings tab: QR + device list + revoke (CLI exists) | 1b |
| Dashboard use of synced data | **Done:** Activity tab, Overview card and measured-burn note in Nutrition (`activity.py`, `/api/state` → `activity`). **Still open:** advisor reads `activity_days`/`nutrition_days`; surface measured `fat_pct_m`/`lean_kg_m` in `reading_dict`; activity on the phone's Overview | 4 |
| Outbox pruning | `sync_outbox` grows by one small row per change; prune rows older than both consumers' cursors | 5 |
| iOS app | HealthStore, SyncEngine, `RelayClient` + direct client behind one `SyncTransport` protocol, same envelope + AAD format | 2–5 |
| Rate limiting | Cloudflare WAF rule on `/v1/*` | before pairing real devices |
| Redeploy relay | Loopback exemption (for `wrangler dev`) is in the repo but not yet deployed; harmless to defer | – |

## 7. Operations runbook (relay)

```bash
cd relay
npm install
npm test                       # 11 tests in the Workers runtime
npx wrangler dev --local --port 8799   # local relay (put ADMIN_CODE in relay/.dev.vars); port 8787 is taken on this Mac
npx wrangler deploy            # publishes to the account
npx wrangler secret put ADMIN_CODE < .admin-code     # rotate: generate a new file first
npx wrangler d1 migrations apply atomhealth-relay --remote
npx wrangler tail              # live logs (relay logs no bodies)
```
Rotate the admin code any time: `openssl rand -base64 36 | tr -d '\n=' | tr '+/' '-_' > .admin-code` then the `secret put` line. Existing device tokens keep working.

## 8. Limits & cost
Without chat the free tier covers ~200–300 requests/day/device vs. ~100k/day allowed; D1 holds KBs. With the phone chat see §8a. Paid fallback: Workers Paid ($5/mo).
