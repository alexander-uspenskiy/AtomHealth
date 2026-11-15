import Foundation

/// The conversation with the Mac's bot, kept on the phone (one JSON file plus the photos in a `media` folder, both
/// with complete file protection) so it opens instantly and works offline.
public actor ChatStore {
    struct State: Codable {
        var messages: [ChatMessage] = []
        var readAt: Double = 0
    }

    public static let maxMessages = 400
    let url: URL
    let mediaDir: URL
    var state: State
    var typingUntil: Date?
    var toast: String?
    var heardAt: Date?
    var aiReady: Bool?

    public init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("chat.json")
        mediaDir = directory.appendingPathComponent("media")
        try? FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(State.self, from: d) { state = s } else { state = State() }
    }

    public func snapshot() -> ChatSnapshot {
        var s = ChatSnapshot()
        s.messages = state.messages
        s.typingUntil = typingUntil
        s.toast = toast; toast = nil
        s.heardAt = heardAt; s.aiReady = aiReady
        s.unread = state.messages.filter { $0.role == .bot && $0.date.timeIntervalSince1970 > state.readAt }.count
        return s
    }

    func save() {
        guard let d = try? JSONEncoder().encode(state) else { return }
        try? d.write(to: url, options: [.atomic, .completeFileProtection])
    }

    public nonisolated func mediaURL(_ name: String, thumbnail: Bool = false) -> URL {
        mediaDir.appendingPathComponent(thumbnail ? "\(name).t.jpg" : "\(name).jpg")
    }

    // MARK: from the Mac
    /// A `chat_out` envelope: a new message, an edit of an earlier one, or one of the two ephemeral signals.
    public func apply(_ env: Envelope) {
        guard env.type == .chatOut, env.op == .upsert, let d = env.data else { return }
        heardAt = Date()
        switch env.id {
        case "presence":
            aiReady = d["ai"]?.boolValue
        case "typing":
            if let t = d["typing_until"]?.doubleValue { typingUntil = Date(timeIntervalSince1970: t) }
        case "toast":
            toast = d["toast"]?.stringValue
        default:
            guard let mid = d["mid"]?.intValue, let text = d["text"]?.stringValue else { return }
            let buttons: [[ChatButton]] = (d["buttons"]?.arrayValue ?? []).map { row in
                (row.arrayValue ?? []).compactMap { b in
                    guard let t = b["text"]?.stringValue, let data = b["data"]?.stringValue else { return nil }
                    return ChatButton(text: t, data: data)
                }
            }.filter { !$0.isEmpty }
            let id = "m\(mid)"
            typingUntil = nil        // any bot message, new or an edit of its "Analysing…" note, ends "typing…"
            if let i = state.messages.firstIndex(where: { $0.id == id }) {
                state.messages[i].text = text; state.messages[i].buttons = buttons
                state.messages[i].edited = d["edited"]?.boolValue ?? true
            } else {
                let ts = d["ts"]?.doubleValue ?? Double(env.updatedAt)
                state.messages.append(ChatMessage(id: id, role: .bot, text: text, buttons: buttons,
                                                  date: Date(timeIntervalSince1970: ts), mid: mid, delivery: .answered))
                for k in state.messages.indices where state.messages[k].role == .user { state.messages[k].delivery = .answered }
            }
            prune(); save()
        }
    }

    // MARK: from the user
    @discardableResult
    public func addUser(text: String, photos: [String]) -> ChatMessage {
        let m = ChatMessage(id: "u-\(UUID().uuidString.lowercased())", role: .user, text: text, photos: photos)
        state.messages.append(m)
        state.readAt = Date().timeIntervalSince1970
        prune(); save()
        return m
    }

    /// Stores a resized photo and its small preview; returns the name that `mediaURL` resolves.
    public func savePhoto(jpeg: Data, thumbnail: Data?) -> String {
        let name = UUID().uuidString.lowercased()
        try? jpeg.write(to: mediaURL(name), options: [.atomic, .completeFileProtection])
        if let thumbnail { try? thumbnail.write(to: mediaURL(name, thumbnail: true), options: [.atomic, .completeFileProtection]) }
        return name
    }

    /// Everything queued has now been handed to the relay.
    public func markSent() {
        var changed = false
        for i in state.messages.indices where state.messages[i].role == .user && state.messages[i].delivery == .sending {
            state.messages[i].delivery = .sent; changed = true
        }
        if changed { save() }
    }

    public func markRead(now: Date = Date()) {
        state.readAt = now.timeIntervalSince1970; save()
    }

    public func remove(id: String) {
        guard let i = state.messages.firstIndex(where: { $0.id == id }) else { return }
        deleteMedia(state.messages[i].photos)
        state.messages.remove(at: i); save()
    }

    public func clear() {
        deleteMedia(state.messages.flatMap(\.photos))
        state = State(); typingUntil = nil; toast = nil; save()   // presence is kept: the Mac is still there
    }

    func prune() {
        let extra = state.messages.count - Self.maxMessages
        guard extra > 0 else { return }
        deleteMedia(state.messages.prefix(extra).flatMap(\.photos))
        state.messages.removeFirst(extra)
    }

    func deleteMedia(_ names: [String]) {
        for n in names {
            try? FileManager.default.removeItem(at: mediaURL(n))
            try? FileManager.default.removeItem(at: mediaURL(n, thumbnail: true))
        }
    }
}
