import Foundation

/// The conversation with the Mac's bot, kept on the phone in a SQLite archive (`chat.sqlite`, complete file protection)
/// plus the photos in a `media` folder. Only the newest `windowSize` messages are ever read into memory, so opening
/// the chat is instant however long the history is; older ones are paged in on demand (`loadEarlier`).
public actor ChatStore {
    /// The legacy single-file store: read once, imported, then removed.
    struct LegacyState: Codable {
        var messages: [ChatMessage] = []
        var readAt: Double = 0
    }

    /// Messages shown when the chat opens, and how many more each `loadEarlier` adds.
    public static let pageSize = 10
    /// A hard stop for the archive (the app suggests cleaning up long before, see `ChatStorageReport`).
    public static let defaultMaxMessages = 5000
    public static var maxMessages: Int { defaultMaxMessages }

    let url: URL
    let legacyURL: URL
    let mediaDir: URL
    let db: ChatDB?
    let maxMessages: Int
    var windowSize = ChatStore.pageSize
    var typingUntil: Date?
    var toast: String?
    var heardAt: Date?
    var aiReady: Bool?

    public init(directory: URL, maxMessages: Int = ChatStore.defaultMaxMessages) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("chat.sqlite")
        legacyURL = directory.appendingPathComponent("chat.json")
        mediaDir = directory.appendingPathComponent("media")
        try? FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        self.maxMessages = maxMessages
        db = ChatDB(url: url)
        // one-time import of a chat saved by an older build
        if let db, let d = try? Data(contentsOf: legacyURL), let old = try? JSONDecoder().decode(LegacyState.self, from: d) {
            db.transaction {
                for m in old.messages { Self.put(m, in: db, mediaBytes: Self.mediaBytes(of: m.photos, in: mediaDir)) }
                db.exec("INSERT OR REPLACE INTO meta(k, v) VALUES('readAt', ?)", [.double(old.readAt)])
            }
            try? FileManager.default.removeItem(at: legacyURL)
        }
    }

    // MARK: reading
    public func snapshot() -> ChatSnapshot {
        var s = ChatSnapshot()
        s.messages = window()
        s.total = count()
        s.typingUntil = typingUntil
        s.toast = toast; toast = nil
        s.heardAt = heardAt; s.aiReady = aiReady
        s.unread = db?.rows("SELECT COUNT(*) FROM messages WHERE role='bot' AND date>?", [.double(readAt)]) { $0.int(0) }.first ?? 0
        return s
    }

    /// Reveals the next page of older messages (the chat calls this when the user reaches the top).
    public func loadEarlier() -> ChatSnapshot {
        windowSize = min(windowSize + Self.pageSize, max(Self.pageSize, count()))
        return snapshot()
    }

    /// Back to the newest page: called whenever the chat is opened, so memory and drawing stay small.
    public func resetWindow() { windowSize = Self.pageSize }

    func window() -> [ChatMessage] {
        let rows: [ChatMessage] = db?.rows("SELECT json FROM messages ORDER BY seq DESC LIMIT ?", [.int(Int64(windowSize))]) {
            try? JSONDecoder().decode(ChatMessage.self, from: $0.blob(0))
        } ?? []
        return rows.reversed()
    }

    func count() -> Int { db?.rows("SELECT COUNT(*) FROM messages") { $0.int(0) }.first ?? 0 }
    var readAt: Double { db?.rows("SELECT v FROM meta WHERE k='readAt'") { $0.double(0) }.first ?? 0 }

    func message(_ id: String) -> ChatMessage? {
        db?.rows("SELECT json FROM messages WHERE id=?", [.text(id)]) { try? JSONDecoder().decode(ChatMessage.self, from: $0.blob(0)) }.first
    }

    // MARK: writing
    /// Inserts or replaces one message; the row keeps its place in the conversation (`seq`) when it is an edit.
    static func put(_ m: ChatMessage, in db: ChatDB, mediaBytes: Int) {
        guard let json = try? JSONEncoder().encode(m) else { return }
        let pending: Int64 = m.role == .user && m.delivery != .answered ? 1 : 0
        let binds: [ChatDB.Bind] = [.text(m.id), .text(m.role.rawValue), .double(m.date.timeIntervalSince1970), .int(pending),
                                    .int(Int64(mediaBytes)), .int(Int64(json.count + mediaBytes)), .blob(json)]
        if !db.exec("UPDATE messages SET role=?2, date=?3, pending=?4, media=?5, bytes=?6, json=?7 WHERE id=?1", binds) { return }
        if sqlite3Changes(db) == 0 {
            db.exec("INSERT INTO messages(id, role, date, pending, media, bytes, json) VALUES(?,?,?,?,?,?,?)", binds)
        }
    }

    static func sqlite3Changes(_ db: ChatDB) -> Int { db.rows("SELECT changes()") { $0.int(0) }.first ?? 0 }

    static func mediaBytes(of names: [String], in dir: URL) -> Int {
        names.reduce(0) { sum, n in
            [dir.appendingPathComponent("\(n).jpg"), dir.appendingPathComponent("\(n).t.jpg")].reduce(sum) {
                $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? Int) ?? 0)
            }
        }
    }

    func store(_ m: ChatMessage) {
        guard let db else { return }
        let media = m.role == .user ? Self.mediaBytes(of: m.photos, in: mediaDir) : 0
        Self.put(m, in: db, mediaBytes: media)
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
            if var m = message(id) {
                m.text = text; m.buttons = buttons
                m.visuals = ChatVisual.parse(d["visuals"])
                m.edited = d["edited"]?.boolValue ?? true
                store(m)
            } else {
                let ts = d["ts"]?.doubleValue ?? Double(env.updatedAt)
                store(ChatMessage(id: id, role: .bot, text: text, buttons: buttons, date: Date(timeIntervalSince1970: ts), mid: mid,
                                  delivery: .answered, visuals: ChatVisual.parse(d["visuals"])))
                changeUserMessages(where: { $0.delivery != .answered }) { $0.delivery = .answered }   // an answer means they were read
            }
            prune()
        }
    }

    /// Rewrites the (few) user messages still waiting for an answer.
    func changeUserMessages(where match: (ChatMessage) -> Bool, _ change: (inout ChatMessage) -> Void) {
        guard let db else { return }
        let waiting: [ChatMessage] = db.rows("SELECT json FROM messages WHERE pending=1") { try? JSONDecoder().decode(ChatMessage.self, from: $0.blob(0)) }
        for var m in waiting where match(m) { change(&m); store(m) }
    }

    // MARK: from the user
    @discardableResult
    public func addUser(text: String, photos: [String]) -> ChatMessage {
        let m = ChatMessage(id: "u-\(UUID().uuidString.lowercased())", role: .user, text: text, photos: photos)
        store(m)
        setReadAt(Date().timeIntervalSince1970)
        prune()
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
    public func markSent() { changeUserMessages(where: { $0.delivery == .sending }) { $0.delivery = .sent } }

    public func markRead(now: Date = Date()) { setReadAt(now.timeIntervalSince1970) }

    func setReadAt(_ t: Double) { db?.exec("INSERT OR REPLACE INTO meta(k, v) VALUES('readAt', ?)", [.double(t)]) }

    public func remove(id: String) {
        guard let m = message(id) else { return }
        deleteMedia(m.photos)
        db?.exec("DELETE FROM messages WHERE id=?", [.text(id)])
    }

    public func clear() {
        let all: [ChatMessage] = db?.rows("SELECT json FROM messages WHERE media>0") { try? JSONDecoder().decode(ChatMessage.self, from: $0.blob(0)) } ?? []
        deleteMedia(all.flatMap(\.photos))
        db?.exec("DELETE FROM messages"); db?.exec("VACUUM")
        windowSize = Self.pageSize; typingUntil = nil; toast = nil     // presence is kept: the Mac is still there
        setReadAt(0)
    }

    /// The hard cap: the oldest messages (and their photos) go once the archive passes `maxMessages`.
    func prune() {
        guard let db, let cut = db.rows("SELECT seq FROM messages ORDER BY seq DESC LIMIT 1 OFFSET ?", [.int(Int64(maxMessages))], { $0.int(0) }).first else { return }
        deleteRows(where: "seq<=?", [.int(Int64(cut))])
    }

    // MARK: storage and cleanup
    /// What the chat occupies and how fast it grows (see `ChatStorageReport`).
    public func storageReport(now: Date = Date()) -> ChatStorageReport {
        let since = now.timeIntervalSince1970 - ChatStorageReport.forecastWindowDays * 86_400
        let all = db?.rows("SELECT COUNT(*), COALESCE(SUM(bytes),0), MIN(date) FROM messages") { ($0.int(0), $0.int(1), $0.double(2)) }.first ?? (0, 0, 0)
        let recent = db?.rows("SELECT COALESCE(SUM(bytes),0) FROM messages WHERE date>=?", [.double(since)]) { $0.int(0) }.first ?? 0
        return ChatStorageReport(messages: all.0, usedBytes: all.1, recentBytes: recent,
                                 oldest: all.0 > 0 ? Date(timeIntervalSince1970: all.2) : nil, now: now)
    }

    /// What deleting everything older than `days` days would free.
    public func cleanupOffer(olderThanDays days: Int, now: Date = Date()) -> ChatCleanupOffer {
        let cut = now.timeIntervalSince1970 - Double(days) * 86_400
        let r = db?.rows("SELECT COUNT(*), COALESCE(SUM(bytes),0) FROM messages WHERE date<?", [.double(cut)]) { ($0.int(0), $0.int(1)) }.first ?? (0, 0)
        return ChatCleanupOffer(days: days, messages: r.0, bytes: r.1)
    }

    /// Deletes messages older than `days` days with their photos; returns what was removed.
    @discardableResult
    public func deleteOlder(thanDays days: Int, now: Date = Date()) -> ChatCleanupOffer {
        let offer = cleanupOffer(olderThanDays: days, now: now)
        deleteRows(where: "date<?", [.double(now.timeIntervalSince1970 - Double(days) * 86_400)])
        db?.exec("VACUUM")                                            // give the freed space back to the file system
        return offer
    }

    func deleteRows(where clause: String, _ binds: [ChatDB.Bind]) {
        guard let db else { return }
        let doomed: [ChatMessage] = db.rows("SELECT json FROM messages WHERE media>0 AND \(clause)", binds) { try? JSONDecoder().decode(ChatMessage.self, from: $0.blob(0)) }
        deleteMedia(doomed.flatMap(\.photos))
        db.exec("DELETE FROM messages WHERE \(clause)", binds)
    }

    func deleteMedia(_ names: [String]) {
        for n in names {
            try? FileManager.default.removeItem(at: mediaURL(n))
            try? FileManager.default.removeItem(at: mediaURL(n, thumbnail: true))
        }
    }
}
