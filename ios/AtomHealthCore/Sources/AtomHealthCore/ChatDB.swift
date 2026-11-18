import Foundation
import SQLite3

/// A tiny SQLite wrapper for the chat archive (the system library, no dependency). Used only inside `ChatStore`.
/// Protection is "until first unlock" (not "complete"): a background sync with the phone locked must still be able to write.
final class ChatDB {
    enum Bind { case int(Int64), double(Double), text(String), blob(Data) }
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)    // SQLITE_TRANSIENT

    init?(url: URL) {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); return nil
        }
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        exec("PRAGMA synchronous=NORMAL")
        exec("""
            CREATE TABLE IF NOT EXISTS messages(
              seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE NOT NULL, role TEXT NOT NULL, date REAL NOT NULL,
              pending INTEGER NOT NULL DEFAULT 0, media INTEGER NOT NULL DEFAULT 0, bytes INTEGER NOT NULL, json BLOB NOT NULL);
            CREATE INDEX IF NOT EXISTS messages_date ON messages(date);
            CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v REAL);
            """)
    }

    deinit { sqlite3_close(db) }

    @discardableResult func exec(_ sql: String, _ binds: [Bind] = []) -> Bool {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(st) }
        if binds.isEmpty { // possibly several statements
            sqlite3_finalize(st); st = nil
            return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
        }
        bind(st, binds)
        return sqlite3_step(st) == SQLITE_DONE
    }

    private func bind(_ st: OpaquePointer?, _ binds: [Bind]) {
        for (i, b) in binds.enumerated() {
            let n = Int32(i + 1)
            switch b {
            case .int(let v): sqlite3_bind_int64(st, n, v)
            case .double(let v): sqlite3_bind_double(st, n, v)
            case .text(let v): sqlite3_bind_text(st, n, v, -1, Self.transient)
            case .blob(let v): v.withUnsafeBytes { _ = sqlite3_bind_blob(st, n, $0.baseAddress, Int32(v.count), Self.transient) }
            }
        }
    }

    func rows<T>(_ sql: String, _ binds: [Bind] = [], _ map: (Row) -> T?) -> [T] {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        bind(st, binds)
        var out: [T] = []
        while sqlite3_step(st) == SQLITE_ROW { if let v = map(Row(st: st)) { out.append(v) } }
        return out
    }

    struct Row {
        let st: OpaquePointer?
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(st, i)) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(st, i) }
        func text(_ i: Int32) -> String { sqlite3_column_text(st, i).map { String(cString: $0) } ?? "" }
        func blob(_ i: Int32) -> Data {
            guard let p = sqlite3_column_blob(st, i) else { return Data() }
            return Data(bytes: p, count: Int(sqlite3_column_bytes(st, i)))
        }
    }

    func transaction(_ body: () -> Void) {
        exec("BEGIN"); body(); exec("COMMIT")
    }
}
