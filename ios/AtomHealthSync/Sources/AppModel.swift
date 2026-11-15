import AtomHealthCore
import AtomHealthKit
import Foundation
import HealthKit
import Observation

@MainActor @Observable
final class AppModel {
    enum Phase { case unpaired, paired }
    enum Tab { case overview, chat, sync }
    /// The selected tab lives here so any screen can switch to another (back from Chat, "Ask the coach" on Overview).
    var tab: Tab = .overview

    var phase: Phase = .unpaired
    var status = "Not paired"
    var lastReport: SyncReport?
    var lastSync: Date?
    var pending = 0
    var error: String?
    var busy = false
    /// The Mac's latest Overview numbers; kept on disk so the tab opens instantly and works offline.
    var dashboard: DashboardSnapshot?
    /// The conversation with the Mac's bot (the Chat tab); kept on disk like the dashboard.
    var chat = ChatSnapshot()
    /// The oldest ping the Mac has not answered yet (or the last answered one): drives "Checking Mac…" / "Mac not responding".
    var pingSentAt: Date?
    var relayOK: Bool { config != nil && status != "Sync failed" && !status.hasPrefix("Device revoked") }

    private var config: (url: String, deviceID: String, token: String, key: Data)?
    private let store: JSONFileStateStore
    private let reader: HealthKitReader
    private let dashboardStore: DashboardStore
    let chatStore: ChatStore
    private let sink: RoutingSink
    private var debounce: Task<Void, Never>?

    init() {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        store = JSONFileStateStore(url: dir.appendingPathComponent("sync-state.json"))
        reader = HealthKitReader(state: store)
        dashboardStore = DashboardStore(url: dir.appendingPathComponent("dashboard.json"))
        chatStore = ChatStore(directory: dir.appendingPathComponent("chat"))
        sink = RoutingSink(health: HealthKitSink(), dashboard: dashboardStore, chat: chatStore)
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
        config = nil; phase = .unpaired; status = "Not paired"; lastReport = nil; lastSync = nil; dashboard = nil
        chat = ChatSnapshot()
        Task { await dashboardStore.clear(); await chatStore.clear() }
    }

    func start() async {
        #if DEBUG
        // Test hook for the simulator only: `simctl launch … -debugPairingCode ahpair1:…` pairs without typing.
        if config == nil, let code = UserDefaults.standard.string(forKey: "debugPairingCode") { pair(code: code) }
        #endif
        guard config != nil else { return }
        dashboard = await dashboardStore.load()
        chat = await chatStore.snapshot()
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

    /// `health: false` is the light cycle the Chat tab runs every few seconds: relay only, no HealthKit refresh.
    func syncNow(health: Bool = true) async {
        guard let c = config, !busy else { return }
        busy = true; defer { busy = false }
        do {
            if health { await reader.refresh() }
            let engine = SyncEngine(deviceID: c.deviceID, key: c.key, relay: try RelayClient(url: c.url, token: c.token),
                                    store: store, sink: sink)
            lastReport = try await engine.cycle(); lastSync = Date(); error = nil; status = "Up to date"
            if !(await store.pending()).contains(where: { $0.type == .chatIn }) { await chatStore.markSent() }
        } catch let e as RelayError {
            error = e.message; status = e.status == 401 ? "Device revoked: pair again" : "Sync failed"
        } catch { self.error = error.localizedDescription; status = "Sync failed" }
        pending = await store.pending().count
        dashboard = await dashboardStore.load()
        chat = await chatStore.snapshot()
    }

    // MARK: chat
    /// Sends text and/or photos (already resized) to the Mac's bot. Photos go as chunks, then one message that ties them.
    func sendChat(text: String, photos: [PhotoPrep.Result] = []) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard config != nil, !text.isEmpty || !photos.isEmpty else { return }
        var changes: [LocalChange] = [], names: [String] = [], ids: [String] = []
        for p in photos.prefix(ChatWire.maxPhotos) {
            names.append(await chatStore.savePhoto(jpeg: p.jpeg, thumbnail: PhotoPrep.thumbnail(p.jpeg)))
            let id = UUID().uuidString.lowercased(); ids.append(id)
            changes += ChatWire.photoChunks(photoID: id, jpeg: p.jpeg)
        }
        changes.append(ids.isEmpty ? ChatWire.text(text) : ChatWire.message(text: text, photoIDs: ids))
        await chatStore.addUser(text: text, photos: names)
        await store.enqueue(contentsOf: changes)
        pending = await store.pending().count
        chat = await chatStore.snapshot()
        await syncNow(health: false)
    }

    /// "Are you there?" to the Mac; it answers with its presence and whether its AI backend is reachable.
    func pingMac() async {
        guard config != nil else { return }
        // keep an unanswered ping's time, so "not responding" does not restart its timer each time we ask again
        if let p = pingSentAt, (chat.heardAt ?? .distantPast) < p {} else { pingSentAt = Date() }
        let queued = await store.pending().contains { $0.data?["kind"]?.stringValue == "ping" }
        if !queued { await store.enqueue(ChatWire.ping()) }
        await syncNow(health: false)
    }

    func tapChatButton(_ message: ChatMessage, _ button: ChatButton) async {
        guard config != nil, let mid = message.mid else { return }
        await store.enqueue(ChatWire.callback(data: button.data, messageID: mid))
        await syncNow(health: false)
    }

    func markChatRead() async { await chatStore.markRead(); chat = await chatStore.snapshot() }
    func deleteChatMessage(_ id: String) async { await chatStore.remove(id: id); chat = await chatStore.snapshot() }
    func clearChat() async { await chatStore.clear(); chat = await chatStore.snapshot() }
    nonisolated func mediaURL(_ name: String, thumbnail: Bool = false) -> URL { chatStore.mediaURL(name, thumbnail: thumbnail) }
}
