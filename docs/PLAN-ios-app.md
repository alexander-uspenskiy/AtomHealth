# iOS companion app: build and install plan (Free Personal Team)

Decision (2026-11-14): sideload from Xcode with a **free Personal Team** (no paid Apple Developer account). Upgrade to the $99/yr membership later only if the free-tier limits get in the way; the code does not change.

Related: [PLAN-apple-health-app.md](PLAN-apple-health-app.md) (product plan), [ARCHITECTURE-sync.md](ARCHITECTURE-sync.md) (relay and envelope), [SECURITY-sync.md](SECURITY-sync.md) (F5: crypto test vectors).

## Free Personal Team limits
- The app **expires after 7 days** and must be re-run from Xcode (about 1 minute). Data is not lost: the relay keeps records for 30 days.
- At most 3 sideloaded apps at a time; a limited number of new App IDs per week.
- No TestFlight, no App Store, no push notifications, no iCloud.
- HealthKit works in development. **Unverified:** whether HealthKit background delivery fires on a free team. Test this first. If it does not, the app still syncs on every open.
- Never share someone else's Apple ID or 2FA; a team invite on a paid account is the legitimate alternative.

## A. One-time setup (user)
1. Install Xcode (Mac App Store, about 15 GB). Open it once; accept the license and components.
2. Xcode > Settings > Accounts: add your Apple ID. A "Personal Team" appears.
3. iPhone: connect by USB, tap "Trust", then Settings > Privacy & Security > Developer Mode > On, and restart. Keep the phone on the same Wi-Fi as the Mac.

## B. Build the app
1. Xcode project `ios/AtomHealthSync/`: SwiftUI, iOS 17+, unique bundle ID `com.<name>.atomhealthsync`.
2. HealthKit capability with background delivery; `NSHealthShareUsageDescription` and `NSHealthUpdateUsageDescription`.
3. Crypto layer (CryptoKit ChaCha20-Poly1305, AAD `atomhealth-v1|device_id|record_id`) with test vectors shared with `relay.py` (F5).
4. Relay client: `/v1/pair`, `/v1/push` (50 records per batch), `/v1/pull`, `/v1/ack`. Device token and data key in the iOS Keychain.
5. HealthKit layer: anchored and observer queries for weight, body fat, active energy, steps, workouts; writes dietary samples as `HKCorrelation(.food)`; a sync identifier on every sample prevents duplicates; only samples this app wrote are edited or deleted.
6. Sync engine: same envelope and last-writer-wins rules as `sync.py`; runs on foreground, background refresh and HealthKit background delivery.
7. Minimal UI: pair (QR or paste), status, last sync, "Sync now".
8. Mac side: pairing screen in the Settings tab that shows the QR code.

## C. First install (together, about 10 min)
1. Select the Personal Team under Signing & Capabilities and the iPhone as the target; Run.
2. iPhone: Settings > General > VPN & Device Management > trust the developer certificate; launch.
3. Pair with `python -m atomhealth.relay pair`; approve the Health permissions.
4. Check both directions: a weight logged on the Mac appears in Apple Health, and one from Apple Health appears in AtomHealth.

## D. Routine
- Re-run from Xcode at least every 7 days (calendar reminder).
- If sync stops, check the app has not expired before debugging the relay.

## Effort and status
| Step | Effort | Status |
|---|---|---|
| A1 Xcode download | 15 GB | done: Xcode 27.2, license accepted (2026-11-14) |
| A2, A3 | 10 min, user | pending |
| B3 crypto layer | 1 hour | **done**: `ios/AtomHealthCore` Swift package, 5 tests pass (`swift test`), byte-identical to Python via `tools/gen_crypto_vectors.py` |
| B4 envelope + relay client | 2 hours | **done**: `Envelope.swift`, `RelayClient.swift` (https-only, 50-record batches, token never in errors), 10 Swift tests pass |
| B1, B2 | 1 hour | pending (need the Apple ID in Xcode) |
| B5 to B8 | 2 to 3 days | pending |
| C | 10 min | pending |

## Notes
- No iOS simulator runtime is installed yet; the core package is tested on macOS (`cd ios/AtomHealthCore && swift test`). Download an iOS runtime in Xcode > Settings > Components to run the app in a simulator.
- Regenerate vectors after any crypto change: `PYTHONPATH=src python tools/gen_crypto_vectors.py ios/AtomHealthCore/Tests/AtomHealthCoreTests/Resources/crypto_vectors.json`.

## Open questions
- Does HealthKit background delivery work on a free team? (test in step C)
- Bundle ID and display name.
- Whether to keep the Shortcut feed (F9) once the app syncs.
