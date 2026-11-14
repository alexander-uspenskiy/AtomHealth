# Security: sync relay and secrets (audit of 2026-11-14)

Scope: `relay/` (Cloudflare Worker + D1), how its secrets are stored on this Mac and in Cloudflare, and the auth surface of the existing AtomHealth service that the sync feature will touch. Static review plus live probes of the deployed relay. Not a penetration test.

## 1. Threat model

| Asset | Adversary | Protection |
|---|---|---|
| Health data (weight, meals, activity) | Cloudflare staff / breach, anyone with D1 access | End-to-end ChaCha20-Poly1305; relay stores ciphertext only; key never leaves phone/Mac |
| Relay write/pair access | Internet attacker | HTTPS only, admin code (≈288 bits) for pairing, per-device random 256-bit tokens (hash stored) |
| Data key | Lost phone/Mac, shoulder-surfing the pairing QR | Keychain storage; one-time QR; revocation + re-pair |
| Local DB (`data/weight.db`) | Other local users / malware | FileVault on; file permissions (see finding F7) |
| Availability | Request flooding | Cloudflare edge; rate-limit rule recommended (F3) |

Out of scope: a compromised phone or Mac (holds the key by design), Cloudflare account takeover (see F8), Apple HealthKit itself.

## 2. Secret storage — verified

| Secret | Where it lives | Check performed | Result |
|---|---|---|---|
| `ADMIN_CODE` | Cloudflare Worker secret; local copy `relay/.admin-code` | `wrangler secret list` shows `ADMIN_CODE` (value not retrievable). File mode `-rw-------` (600). `git check-ignore` confirms ignored. Loop-grep of all tracked and unignored-untracked files for the value: **0 hits**. Not in `~/.zsh_history` or fish history. FileVault: **On**. | ✅ |
| Device tokens | Not yet issued | – | n/a |
| Data key | Not yet created | Design: Keychain only (never `.env`, never the relay) | n/a |
| Wrangler OAuth token | `~/Library/Preferences/.wrangler/config/default.toml`, mode 600 | Permissions OK, but scopes are broad (account-wide incl. workers, D1, secrets, queues…) | ⚠️ F8 |
| Mac device token + data key | macOS Keychain via `keyring` (service `atomhealth-relay`), or `RELAY_TOKEN`/`RELAY_KEY` env vars | Never written to SQLite, `.env` or logs; `pair` does not print the token; tests assert errors do not echo it | ✅ (implemented 2026-11-14) |
| Existing `health_token`, Telegram token | SQLite `kv` table in `data/weight.db` | Plaintext in a DB that is mode 644 | ⚠️ F7 |
| Git history | – | No secret-like strings in tracked files (only code identifiers such as `api_key="k"` in tests) | ✅ |

The admin code was generated locally, written straight to the file, and never printed to the terminal or chat.

## 3. Findings

| ID | Severity | Finding | Status |
|---|---|---|---|
| F1 | **High** | Deployed relay answered **plain HTTP** (`http://…workers.dev` returned 200). An admin code or device token sent over HTTP could be sniffed. | **Fixed and deployed** (403 on non-HTTPS + HSTS; verified live 2026-11-14, version b95041dd) |
| F2 | Low | No `nosniff`/HSTS/referrer headers. | Fixed and deployed with F1 |
| F3 | Medium | No rate limiting: attacker can burn the free request quota (availability) or hammer `/v1/pair`. Brute force of the admin code is infeasible (≈288 bits) but each attempt costs a request. | **Open** — add a Cloudflare WAF rate-limiting rule for `/v1/*` (dashboard → Security → WAF → Rate limiting rules; one rule is free) |
| F4 | Low | Every authenticated request wrote `last_seen` to D1 (write amplification toward the 100k writes/day cap). | Fixed and deployed (≤ 1 write / 5 min) |
| F5 | Medium (design) | Relay can drop, reorder, replay or swap ciphertexts. | Mitigated by design — **AAD binding** `(device_id, record_id)`, per-entity `version`, last-writer-wins. Must be implemented in clients and covered by cross-language test vectors |
| F6 | Low | Device-count check in `/pair` is not atomic (two simultaneous pairs could exceed 5). Needs the admin code to exploit. | Accepted |
| F7 | Low–Medium | `data/` is `drwxr-xr-x` and `weight.db`, `weight.db.bak-*` are `-rw-r--r--`; the DB holds health data plus the health token and Telegram bot token in plaintext. Any local account can read them (FileVault protects only at rest/off). | **Open** — recommend `chmod 700 data && chmod 600 data/weight.db*`; move secrets to Keychain later. Not changed (running service) |
| F8 | Medium | Wrangler's OAuth login holds account-wide scopes on this Mac. | **Open** — run `npx wrangler logout` when not deploying; for CI/automation use an API token scoped to Workers + D1 edit only; enable 2FA on the Cloudflare/Google account |
| F9 | Low | Existing Shortcut feed puts the health token in the URL (`/api/health/pending?token=…`) — ends up in logs/history; with `--lan` it travels over plain HTTP. (Checked: not present in `data/server.log`.) | **Open** — retire this feed once the iOS app syncs; until then avoid `--lan` on untrusted networks |
| F12 | Medium | Found after the first restart: the service prints `Health token: <value>` at startup (`main()` in `app.py`) and launchd appends stdout to `data/server.log`, which is mode 644. The token also guards `/api/sync/v1` and the Shortcut feed. (The earlier "not in server.log" check only searched for `token=`.) | **Fixed 2026-11-14** — startup banner no longer prints the token (`startup_banner`, tested); old log lines redacted in place; `server.log` is mode 600; token rotated (old one returns 401); `/api/health` token check is now constant-time. Any iOS Shortcut using the old token must be updated from the Settings tab |
| F10 | Info | wrangler sends anonymous usage telemetry. | Optional: `export WRANGLER_SEND_METRICS=false` |
| F11 | Info | Dependencies: `npm audit` → 0 vulnerabilities (relay). `.env`, `.dev.vars`, `.admin-code`, `node_modules` all gitignored. | ✅ |

### Added with the Mac-side code (2026-11-14)
- **Loopback exemption in the Worker** (`http://localhost` allowed so `wrangler dev` works). Deployed Workers are routed by hostname, so a request cannot reach the production Worker as `localhost`. Repo only; production still enforces HTTPS everywhere until the next deploy.
- **Forgery/replay tests:** records re-bound to another sender or record id, bit-flipped ciphertext and wrong keys all fail AEAD authentication and are skipped; replayed phone records do not duplicate data (version check); a revoked device gets 401 on its next cycle (verified against a local relay).
- **Inbound validation:** envelopes are strictly validated (type allow-list, numeric ranges, day format, no bools-as-numbers, meals are outbound-only) before touching SQLite, and each is applied in its own transaction.
- **`/api/sync/v1`** uses constant-time token comparison and prefers a Bearer header over `?token=`; it is reachable over `--lan` like the old health feed, so use it only on trusted networks/TLS (F9 still applies).
- Existing `data/weight.db` gets additive migrations (new columns, tables, triggers) on the next service start; no data is rewritten.

### Verified good
- **SQL injection:** every query uses bound parameters; the only dynamic SQL is the `IN (?2,…)` placeholder list built from the validated record count (≤ 50).
- **Auth comparisons:** SHA-256 of both sides, then `timingSafeEqual`; unknown device and wrong secret return the same 401.
- **Input limits:** body ≤ 1 MB, ≤ 50 records, per-field size and charset checks, strict JSON; unauthenticated oversized bodies are rejected (401 before reading).
- **Error handling:** clients get generic errors; the Worker logs only error messages, never request bodies or tokens; Workers observability is not enabled.
- **No CORS:** the API is for native clients only; browsers cannot call it cross-origin.
- **Isolation:** `pull` returns other devices' records only; revoked devices get 401 immediately.
- **Tests:** 11 tests cover pairing/auth, delivery, idempotency, validation, revocation, device cap, cleanup, HTTPS enforcement and headers.

## 4. Required before pairing real devices
1. ~~Redeploy the relay with F1/F2/F4 fixes~~ — done; plain HTTP now returns 403.
2. Add the WAF rate-limit rule (F3).
3. Implement client crypto with AAD and add Swift ↔ Python test vectors (F5).
4. `chmod` the `data/` directory and DB files (F7).
5. `wrangler logout` after deploys, and enable 2FA on the account (F8).
