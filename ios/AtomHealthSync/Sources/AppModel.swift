import AtomHealthCore
import AtomHealthKit
import Foundation
import HealthKit
import Observation

@MainActor @Observable
final class AppModel {
    enum Phase { case unpaired, paired }

    var phase: Phase = .unpaired
    var status = "Not paired"
    var lastReport: SyncReport?
    var lastSync: Date?
    var pending = 0
    var error: String?
    var busy = false

    private var config: (url: String, deviceID: String, token: String, key: Data)?
    private let store: JSONFileStateStore
    private let reader: HealthKitReader
    private let sink = HealthKitSink()
    private var debounce: Task<Void, Never>?

    init() {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        store = JSONFileStateStore(url: dir.appendingPathComponent("sync-state.json"))
        reader = HealthKitReader(state: store)
        if let u = Keychain.get("url").flatMap({ String(data: $0, encoding: .utf8) }),
           let d = Keychain.get("device").flatMap({ String(data: $0, encoding: .utf8) }),
           let t = Keychain.get("token").flatMap({ String(data: $0, encoding: .utf8) }),
           let k = Keychain.get("key") {
            config = (u, d, t, k); phase = .paired; status = "Paired"
        }
    }

    func pair(code: String) {
        let p: PairingPayload
        do { p = try PairingPayload.decode(code) }
        catch { self.error = "That pairing code is not valid. Create a new one on the Mac."; return }
        do {
            try Keychain.set(Data(p.url.utf8), for: "url"); try Keychain.set(Data(p.deviceID.utf8), for: "device")
            try Keychain.set(Data(p.token.utf8), for: "token"); try Keychain.set(p.key, for: "key")
        } catch {
            ["url", "device", "token", "key"].forEach(Keychain.delete)   // never leave half a pairing behind
            self.error = "Could not save the credentials to the Keychain (\((error as NSError).code))."; return
        }
        config = (p.url, p.deviceID, p.token, p.key); phase = .paired; self.error = nil; status = "Paired"
    }

    func unpair() {
        ["url", "device", "token", "key"].forEach(Keychain.delete)
        config = nil; phase = .unpaired; status = "Not paired"; lastReport = nil; lastSync = nil
    }

    func start() async {
        guard config != nil else { return }
        do {
            try await reader.requestAuthorization()
            reader.onChange = { [weak self] in Task { @MainActor in self?.scheduleSync() } }
            try await reader.start()
        } catch { self.error = "Health access: \(error.localizedDescription)" }
        await syncNow()
    }

    /// Several Health changes arrive in bursts; sync once after they settle.
    func scheduleSync() {
        debounce?.cancel()
        debounce = Task { try? await Task.sleep(for: .seconds(5)); if !Task.isCancelled { await syncNow() } }
    }

    func syncNow() async {
        guard let c = config, !busy else { return }
        busy = true; defer { busy = false }
        do {
            await reader.refresh()
            let engine = SyncEngine(deviceID: c.deviceID, key: c.key, relay: try RelayClient(url: c.url, token: c.token),
                                    store: store, sink: sink)
            lastReport = try await engine.cycle(); lastSync = Date(); error = nil; status = "Up to date"
        } catch let e as RelayError {
            error = e.message; status = e.status == 401 ? "Device revoked: pair again" : "Sync failed"
        } catch { self.error = error.localizedDescription; status = "Sync failed" }
        pending = await store.pending().count
    }
}
