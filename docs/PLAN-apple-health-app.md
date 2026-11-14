# Plan: AtomHealth iOS companion app — two-way Apple Health sync

## 1. Goal and context

AtomHealth today is a local Python/aiohttp service on the user's Mac (SQLite `data/weight.db`)
with a PWA dashboard. Apple Health integration is one-way and manual: `/api/health/pending` +
`/api/health/ack` feed an iOS Shortcut that writes **weight / body fat / lean mass / BMI** into Health.
Nothing flows back, and nutrition and activity are not synced at all.

**Goal:** a native iOS app (the only place HealthKit exists — it has no web/server API) that
syncs, in both directions and automatically in the background:

| Data | AtomHealth → Health | Health → AtomHealth |
|---|---|---|
| Weight (`bodyMass`) | scale readings, manual entries | readings from other scales/apps (Withings, manual in Health) |
| Body fat %, lean mass, BMI | estimated values from `bodycomp.py` | measured values from smart scales |
| Nutrition (kcal, protein, carbs, fat, fiber) | confirmed meals (Telegram/photo analysis) | meals logged in other apps (MyFitnessPal, Lose It, Health manual) |
| Activity | – | active kcal, basal kcal, steps, workouts (feeds TDEE/advisor) |

## 2. Requirements

### Functional
- **F1 Authorisation** – granular HealthKit permission screen; per-type toggles for read and write; app works with any subset granted.
- **F2 Push (AtomHealth → Health)** – new/edited/deleted readings and confirmed meals are written to Health. Meals are written as `HKCorrelation(.food)` with kcal + macros so they appear as one entry. Deleting in AtomHealth deletes only what this app wrote.
- **F3 Pull (Health → AtomHealth)** – weight, body comp, dietary samples (from other sources), active/basal energy, steps, workouts are fetched incrementally and posted to the server.
- **F4 Background sync** – HealthKit background delivery wakes the app on new samples; plus `BGAppRefreshTask` as a fallback and a manual "Sync now".
- **F5 No loops, no duplicates** – a sample's origin is tracked; our own writes are never re-imported; the same weigh-in arriving from two sources is merged (see §5.4).
- **F6 Sync status UI** – last sync time, per-type counts, error list, conflict log, "re-sync from date X".
- **F7 Server discovery & pairing** – Bonjour (`_atomhealth._tcp`) on LAN, manual URL for Tailscale/VPN, QR-code pairing that carries the token (reuses existing health token).
- **F8 Dashboard additions** – Activity tile (kcal burned, steps), TDEE computed from real expenditure instead of formula only; advisor uses logged activity.
- **F9 Settings** – sync window (default last 90 days on first sync), conflict preference (which source wins), pause sync, disconnect + optional deletion of app-written samples.

### Non-functional
- **Privacy** – health data stays on the phone ↔ the user's own server. No third-party analytics/SDKs. Token in Keychain. TLS or local-network-only (see §4).
- **Reliability** – idempotent, resumable, safe to kill mid-sync; at-least-once delivery with dedupe; offline queue when the server is unreachable.
- **Battery** – anchored queries only (no full scans); batch ≤ 500 samples per request; coalesce observer wakeups.
- **Compat** – iOS 17+, iPhone only (iPad not needed; Apple Watch app out of scope — Watch data arrives via Health).
- **Compliance** – App Store guideline 5.1.3 (health data): purpose strings, privacy policy, no ads/data-mining use. Distribution can start as TestFlight/ad-hoc.

### Out of scope (v1)
Apple Watch app, widgets/Live Activities, cloud backend, multi-user, Android/Health Connect (the sync API in §5 is designed so it can be added later), clinical records, sleep/heart-rate.

## 3. Architecture

```
┌──────────────────────── iPhone ────────────────────────┐        ┌──────────── Mac (existing) ────────────┐
│ SwiftUI app                                            │        │ aiohttp service                         │
│  ├ UI (status, settings, pairing)                      │        │  ├ /api/sync/v1/*   (NEW)               │
│  ├ SyncEngine (actor)                                  │  HTTPS │  ├ sync.py          (NEW, conflict/dedupe)│
│  │   ├ HealthStore  ── HKHealthStore                   │ ◄────► │  ├ SQLite: readings, meals, activity_*, │
│  │   │    ├ AnchoredObjectQuery per type (read)        │  JSON  │  │         sync_log, tombstones         │
│  │   │    ├ ObserverQuery + background delivery        │  over  │  └ advisor / bodycomp use activity data  │
│  │   │    └ save / delete (write)                      │ LAN or │                                         │
│  │   ├ ServerClient (URLSession, Bonjour, Keychain)    │ Tailsc.│ Telegram bot, scale BLE (unchanged)     │
│  │   └ LocalStore (SwiftData): anchors, id map, queue  │        └─────────────────────────────────────────┘
│  └ BGTaskScheduler / background delivery               │
└────────────────────────────────────────────────────────┘
```

### 3.1 iOS app modules
| Module | Responsibility |
|---|---|
| `HealthStore` | Wraps `HKHealthStore`; type registry (`SyncType` enum → HK identifier, unit, server field); read via `HKAnchoredObjectQuery`, write via `save`, delete via `delete`. |
| `SyncEngine` (Swift actor) | Orchestrates a cycle: **pull server changes → write to Health → read Health changes → push to server → persist anchors**. Single-flight; retries with backoff. |
| `ServerClient` | REST client, token auth, Bonjour resolver, ATS/local-network config. |
| `LocalStore` (SwiftData) | Per-type `HKQueryAnchor` (archived), server cursor, ID map `(serverId ↔ HKObject.uuid)`, outbound queue, sync log. |
| `Scheduler` | `enableBackgroundDelivery(.immediate/.hourly)`, `HKObserverQuery`, `BGAppRefreshTask`. |
| `UI` | Onboarding, permissions, status dashboard, settings, debug log export. |

Stack: Swift 5.10+/6, SwiftUI, SwiftData, HealthKit, BackgroundTasks, Network.framework; XCTest + HealthKit mock protocol.
Entitlements: `com.apple.developer.healthkit`, `healthkit.background-delivery`; Info.plist: `NSHealthShareUsageDescription`, `NSHealthUpdateUsageDescription`, `NSLocalNetworkUsageDescription`, `NSBonjourServices`.

### 3.2 HealthKit mapping
| AtomHealth field | HK type | Dir |
|---|---|---|
| `readings.weight` | `bodyMass` (kg) | ↔ |
| fat_pct | `bodyFatPercentage` | ↔ (estimated values tagged `metadata: estimated=true`) |
| lean_kg | `leanBodyMass` | ↔ |
| bmi | `bodyMassIndex` | → |
| meal kcal/macros | `dietaryEnergyConsumed`, `dietaryProtein`, `dietaryCarbohydrates`, `dietaryFatTotal`, `dietaryFiber` in `HKCorrelation(.food)` | ↔ |
| activity | `activeEnergyBurned`, `basalEnergyBurned`, `stepCount`, `HKWorkout` | ← |

### 3.3 Server changes (Python)
New schema (same `CREATE TABLE IF NOT EXISTS` / `ALTER TABLE` style as `app.py`):
- `readings` += `external_id TEXT UNIQUE`, `updated_at INTEGER`, `deleted_at INTEGER`; `source` gains `applehealth`.
- `meals` += `external_id`, `updated_at`, `deleted_at`; source `applehealth` allowed (items optional — HK has totals only).
- `activity_days(day, active_kcal, basal_kcal, steps, source, updated_at)` + `workouts(id, external_id, start, end, type, kcal, distance_m)`.
- `sync_log(id, ts, device, direction, type, count, status)`; `kv` holds server `change_seq` counter.
- Every mutation bumps a monotonically increasing `change_seq` so the phone can ask "what changed since N" (deletes via tombstones).

New module `sync.py` + endpoints (token-authenticated, replace Shortcut feed; keep old endpoints until deprecated):
- `GET  /api/sync/v1/changes?since=<seq>&types=weight,meal` → `{items:[{type, id, op: upsert|delete, version, data}], next_seq}`
- `POST /api/sync/v1/push` → batch of `{type, external_id, op, version, data}`; returns per-item `{status: created|merged|duplicate|rejected, server_id}` (idempotent by `external_id`).
- `POST /api/sync/v1/ack` → phone confirms HK writes, giving `server_id ↔ hk_uuid` so server records `external_id`.
- `GET  /api/sync/v1/status`, `GET /api/sync/v1/config` (profile units, types enabled).

## 4. Connectivity decision (the biggest design risk)
The server lives on a Mac behind home Wi-Fi, so the phone can't always reach it.

| Option | Pros | Cons | Cost |
|---|---|---|---|
| **A. LAN + Bonjour only** | zero infra, private | syncs only at home | $0 |
| **B. A + Tailscale (recommended)** | works anywhere, E2E-encrypted, MagicDNS + HTTPS certs | user installs Tailscale; Mac must be awake | $0 (personal plan) |
| C. Cloud relay (store-and-forward) | works with Mac asleep | health data on third-party infra, more compliance work | ~$10–40/mo |

**DECISION: Cloudflare free tier relay (Worker + D1, end-to-end encrypted) is the permanent sync point** — see §4.1 and §4.2. Direct LAN/Tailscale (A+B) stays as an optional fast path when the Mac is reachable; the relay is the default path. The phone's outbound queue + HK anchors make offline periods harmless.

### 4.1 Always-on sync point options (Mac asleep) — budget comparison

Free-tier limits change; verify before committing.

| # | Option | How it works | Cost | Privacy | Verdict |
|---|---|---|---|---|---|
| 1 | **Move the whole service to an always-on box** (Raspberry Pi / mini PC, Tailscale) | Same Python service + SQLite; Pi has BLE for the scale | ~$60–90 once, ~$5/yr power | Fully private | **Simplest; no relay code.** Also fixes scale readings and the Telegram bot going dark when the Mac sleeps |
| 2 | **Cloudflare Worker + D1 (or R2) mailbox**, end-to-end encrypted | Phone and Mac both push/pull encrypted change batches; Worker stores ciphertext only | $0 on free tier (~100k req/day, 5 GB D1); ~$5/mo if exceeded | Server never sees plaintext | **Best cloud option** — real HTTP API, no cold-start sleep |
| 3 | **CloudKit (private DB)** | Phone writes to user's own iCloud; Mac polls via CloudKit Web Services | $0 (counts against the user's iCloud quota) | Apple-held, tied to the user's account | Good if Apple-only forever; Mac side needs a server-to-server key and is clunkier in Python |
| 4 | Supabase / Firebase free tier | Hosted Postgres/Firestore + auth | $0 (Supabase free projects pause after ~1 week idle) | Provider sees plaintext unless E2E | Works; more than needed |
| 5 | Mac stays awake | `caffeinate`, `pmset`, Wake-on-LAN, Power Nap | $0 | Private | Fragile on a laptop; ok on a desktop |
| 6 | **GitHub** | see below | $0 | Risky | Not recommended |

**Can GitHub Pages be the sync point? No.**
- Pages is static hosting: it serves files, it cannot accept writes. The phone cannot "save" to a Pages site.
- Pages sites are publicly readable (private-repo Pages needs Enterprise Cloud). Health data there would be public.
- A *workaround* exists: the app commits encrypted JSON to a **private repo** via the GitHub Contents API (fine-grained PAT in Keychain), and the Mac pulls it. It is free and the repo is private, but: no atomic or concurrent writes (409 conflicts), history keeps every version forever, PAT in the app is a standing credential, rate limits (5k req/h) and it violates the spirit of GitHub's terms for data hosting. Only acceptable for a hobby build with client-side encryption.

**Recommendation:** (1) if you want the cheapest, least-code solution and you're fine owning a small always-on device; otherwise (2) with E2E encryption. Both reuse the same `/api/sync/v1` contract: the relay is just another server implementing `changes`/`push`, and the Mac pulls from it as a third "device".

**Impact on budget:** (1) saves ~2 weeks of relay work (≈ −$7k at the team rate); (2) adds ~1.5 weeks (Worker, E2E crypto, Mac-side puller, ≈ +$6–8k); (3) adds ~2 weeks.

### 4.2 Chosen design: Cloudflare Worker + D1 encrypted mailbox

```
 iPhone app                     Cloudflare (free)                     Mac / Pi (AtomHealth)
 HealthKit ⇄ SyncEngine ──push/pull──► Worker ⇄ D1 ◄──push/pull── relay.py ⇄ SQLite (source of truth)
 encrypt/decrypt (Keychain key)      ciphertext only            encrypt/decrypt, scale BLE, Telegram bot
```

- **Role:** a dumb, always-on append-only log. Phone and Mac keep full copies; the relay only holds changes in transit and can be wiped without data loss.
- **Worker API** (`/v1`, bearer token per device):
  - `POST /push` – batch (≤ 50, keeps D1 queries inside free-plan limits) of `{record_id, nonce, ciphertext}` → appended; returns assigned `seq` per record.
  - `GET /pull?since=<seq>&limit=500` – records from *other* devices after the cursor.
  - `POST /ack` – device reports its cursor (drives cleanup).
  - `POST /pair` / `DELETE /device/{id}` – enroll and revoke devices (pairing needs a one-time admin code).
- **D1 schema:** `changes(seq INTEGER PRIMARY KEY AUTOINCREMENT, device_id, record_id, nonce BLOB, ciphertext BLOB, created_at)` and `devices(device_id PK, token_hash, cursor, last_seen)`.
- **Encryption:** 256-bit key generated on the phone, delivered to the Mac via the pairing QR, stored in iOS Keychain / macOS Keychain (or `.env`). ChaChaPoly (CryptoKit) ↔ `cryptography` (Python). Plaintext envelope contains type, op, version, `updated_at`, data — so Cloudflare cannot see record types or values.
- **Merge rules** (§5.4) are applied on the clients; the relay never interprets data. Deletes are `op: delete` records.
- **Mac side:** `relay.py` background task in the aiohttp app – on startup, on wake, and every 5 min: pull → apply to SQLite via `sync.py`; push local changes (scale readings, Telegram meals, edits). The existing `/api/sync/v1` semantics (`change_seq`, tombstones, idempotent `external_id`) are reused as the payload layer; only the transport differs.
- **Phone side:** `RelayClient` implements the same `SyncTransport` protocol as `ServerClient`; engine prefers direct LAN when reachable, else relay.
- **Retention:** cron trigger deletes rows already past every device's cursor and anything > 30 days old.
- **Security:** per-device tokens (hash only in D1), TLS only, Cloudflare rate limiting, payload size caps, no logging of bodies; token revocation tested.
- **Free-tier fit:** ~200–300 requests/day per device and kilobytes of rows vs. ~100k req/day and 5 GB limits (verify current numbers).
- **Deployment:** `wrangler` project in `relay/` of this repo (`wrangler.toml`, `migrations/`, `src/index.ts`); CI deploy via `wrangler deploy`; optional custom domain ($10/yr), otherwise `*.workers.dev`.
- **Tests:** Worker unit tests (vitest + miniflare), cross-language crypto test vectors (Swift ↔ Python), end-to-end scenario: Mac offline → phone changes → Mac wakes → converges; token revocation; duplicate push idempotency.
- **Known limits:** Mac is not woken by the relay (catches up on wake); Cloudflare sees timing/volume metadata; key loss means re-pairing (both ends hold full data, so nothing is lost).

## 5. Sync design

### 5.1 One cycle
1. Pull `GET /changes?since=server_seq` → apply to Health (create/update/delete app-owned samples) → record id map.
2. For each enabled type: `HKAnchoredObjectQuery(anchor)` → new + deleted objects.
3. Filter out samples whose source is this app's bundle (and whose UUID is in the id map).
4. `POST /push` in batches; on success persist new anchor + server cursor **atomically** (anchor advances only after server ack).

### 5.2 Identity & idempotency
- Writes to Health set `HKMetadataKeySyncIdentifier = "atomhealth:<type>:<server_id>"` and `HKMetadataKeySyncVersion = version` → re-saving replaces rather than duplicates.
- Pushes use `external_id = hk_uuid`; server upserts on it.

### 5.3 Deletes & edits
- HealthKit only lets an app delete/modify **its own** samples. AtomHealth deletes/edits → applied to Health for app-written samples; for samples from other apps the server keeps its copy marked `hidden` locally and surfaces a note.
- Deletions in Health arrive as `deletedObjects` from the anchored query → server tombstone.
- Meals are edited in AtomHealth (status pending → confirmed → discarded): only `confirmed` meals go to Health; `discarded` removes the Health correlation.

### 5.4 Duplicate & conflict rules
- **Weight:** reading from Health is a duplicate of an existing one if |Δt| ≤ 2 min and |Δkg| ≤ 0.1 (e.g. the scale's own app already wrote it). Duplicate → link `external_id`, keep AtomHealth row.
- **Nutrition:** dietary samples from other apps are aggregated per day on the phone and stored in a separate `nutrition_days` table (never in `meals`), so they cannot double-count with Telegram/photo meals. A per-day setting **"Nutrition source of truth"** (AtomHealth only / Health only / sum) decides what the advisor uses – default AtomHealth wins. *(Implemented: table + sync; the setting comes with the dashboard work.)*
- **Body fat/lean:** measured (from Health) beats estimated (formula) in dashboard and advisor.
- **Version conflict (both edited):** last-writer-wins by `updated_at`, loser logged in `sync_log` and shown in app.
- **Activity:** read-only, aggregated per day server-side (sum of samples; dedupe overlapping sources using HK's own `HKStatisticsCollectionQuery` with `.separateBySource` off so Health picks the priority source).

### 5.5 Edge cases
Timezone/DST (store UTC + tz offset), unit changes (always kg/kcal/g on the wire), huge first sync (windowed backfill, resumable, progress UI), permission revoked mid-flight (HK hides data silently → treat empty as "unknown", prompt re-auth), device locked (HealthKit data is unreadable while locked → background delivery runs on next unlock, handle `errorDatabaseInaccessible`), token rotation, Mac offline.

## 6. Delivery plan

| Phase | Weeks | Deliverables | Exit criteria |
|---|---|---|---|
| 0. Spike & decisions | 1 | Run HK read/write spike on device; Tailscale/Bonjour reachability test; sync API contract (OpenAPI); data-model review | Contract signed off; background delivery proven on device |
| 1. Server sync API | 2 | Schema migration, `sync.py`, tombstones, `change_seq`, pytest suite, token/pairing QR in Settings tab | API tests green; old Shortcut feed still works |
| 1b. Cloudflare relay | 1.5 | Worker + D1 + migrations, E2E crypto (Swift/Python vectors), `relay.py` on Mac, pairing QR, retention cron | Mac-offline scenario converges; relay holds only ciphertext |
| 2. iOS core: weight & body comp, both ways | 3 | Project, HealthStore, SyncEngine, LocalStore, pairing, status UI | Weigh-in on scale → in Health in < 1 min; manual Health entry → in dashboard; no loops |
| 3. Nutrition both ways | 2 | Food correlations write/read, source-of-truth setting, meal edit/delete propagation | Telegram meal confirmed → Health with macros; delete removes it |
| 4. Activity pull + advisor/dashboard | 2 | activity_days/workouts, Overview tile, advisor + TDEE use real burn | Advisor text cites actual kcal burned |
| 5. Background, hardening, QA | 2 | Background delivery + BG refresh, offline queue, conflict log, battery profiling, UI polish, accessibility | 7-day soak on 2 devices; zero dupes/loops; crash-free |
| 6. Release | 1 | Privacy policy, App Privacy labels, TestFlight, README/docs | TestFlight build live |
| **Total** | **~14.5 weeks** (≈ 12.5 if phases 1–2 overlap) | | |

## 7. Team & budget

Assumptions: blended rate **$85/h** (range $70–110), 40 h/week, USD, excludes taxes/overheads.

| Role | Allocation | Hours | Cost @ $85/h |
|---|---|---|---|
| iOS engineer (Swift/HealthKit) | 100% × 12 wks | 480 | $40,800 |
| Backend engineer (Python/SQLite/TypeScript Worker; knows this repo) | 50% × 8 wks | 160 | $13,600 |
| UI/UX designer | ~3 wks part-time | 60 | $5,100 |
| QA (device matrix, soak tests, test plan) | 50% × 5 wks | 100 | $8,500 |
| PM / tech lead (planning, reviews) | 10% × 13 wks | 52 | $4,420 |
| **Labor subtotal** | | **852** | **$72,420** |
| Contingency 20% (HealthKit background quirks, App Review iteration) | | | $14,484 |
| **Labor total** | | | **≈ $86,900** |

Non-labor:
| Item | Cost |
|---|---|
| Apple Developer Program | $99 / yr |
| Test devices (2 iPhones on different iOS versions + optional Apple Watch for activity data), if not owned | $0 – $1,500 |
| Tailscale (personal) | $0 |
| Cloudflare Workers + D1 relay (free tier; paid fallback $5/mo) | $0 (≤ $60 / yr) |
| Domain + hosted privacy policy page | ~$20 / yr |
| CI (Xcode Cloud, 25 h/mo included with Developer Program) | $0 |
| **Non-labor total (year 1)** | **≈ $120 – $2,100** |

**Headline budget (with Cloudflare relay): ≈ $87k – $89k, ~14.5 weeks, team of ~2.5 FTE peak.**

Cheaper variants:
- **Solo-dev MVP** (weight + body comp + nutrition both ways, activity read-only deferred, no designer/QA): ~9 weeks × 1 engineer ≈ **$32k–$37k** incl. contingency and the relay.
- **Hobby/personal build** (the user builds with Claude Code help): ~250–350 hours own time; cash cost ≈ $99.

Ongoing run cost: ~$99/yr + ~10–15% of build cost per year for iOS-release maintenance (~$8–12k/yr professional; ~20 h/yr hobby).

## 8. Testing strategy
- **Server:** pytest for sync endpoints — idempotent push, tombstones, merge rules, `change_seq` ordering (extends `tests/`).
- **iOS unit:** `HealthStoring` protocol with an in-memory fake; test dedupe, anchor advancement, loop prevention, retry/backoff.
- **Integration:** real device + local server with seeded data; scripted scenarios (scale reading, Withings import, meal edit/delete, airplane mode, locked phone, permission revoke).
- **Soak:** 7 days, two devices, assert row-count parity and zero duplicates via a debug "reconcile" report.
- **Simulator caveat:** HealthKit works in simulator for read/write but not real background delivery/Watch data → device testing mandatory.

## 9. Risks
| Risk | Impact | Mitigation |
|---|---|---|
| Mac asleep / unreachable | sync delays | Tailscale + outbound queue + anchors; clear status UI; optional relay later |
| Background delivery not firing (iOS throttling, low power mode) | stale data | observer + BG refresh + sync-on-foreground; show "last synced" |
| Double counting nutrition from multiple apps | wrong advice | explicit source-of-truth setting, per-source totals visible |
| Can't edit other apps' samples | one-way divergence | tombstone/hidden flag; document limitation |
| Estimated body-fat polluting Health with non-measured data | trust | metadata flag; toggle to not write estimates (default **off**) |
| App Review rejection (health data) | launch delay | purpose strings, privacy policy, no analytics; TestFlight/ad-hoc fallback for personal use |
| HK locked-device read failures | gaps | handle `errorDatabaseInaccessible`, retry on `protectedDataDidBecomeAvailable` |

## 10. Open questions
1. Personal tool (TestFlight to the owner/family) or App Store product? Drives compliance, QA and budget (hobby vs. ~$79k).
2. ~~Tailscale or hosted relay?~~ **Decided: Cloudflare free-tier E2E-encrypted relay**; Tailscale/LAN optional fast path.
3. Default for writing *estimated* body fat/lean mass to Health: off (recommended) or on?
4. Should activity data change calorie targets automatically in the advisor, or stay informational?
5. Apple Watch companion in a later phase?
