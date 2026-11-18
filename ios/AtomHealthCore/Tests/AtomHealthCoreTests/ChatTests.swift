import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AtomHealthCore

// MARK: helpers
func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

/// A noisy test photo (noise does not compress, like a real photo), as JPEG or PNG.
func testImage(width: Int, height: Int, type: UTType = .jpeg, alpha: Bool = false) -> Data {
    let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)!
    var g = SystemRandomNumberGenerator()
    for _ in 0..<4000 {
        ctx.setFillColor(red: .random(in: 0...1, using: &g), green: .random(in: 0...1, using: &g),
                         blue: .random(in: 0...1, using: &g), alpha: alpha ? 0.5 : 1)
        ctx.fill(CGRect(x: .random(in: 0..<Double(width), using: &g), y: .random(in: 0..<Double(height), using: &g),
                        width: .random(in: 4...60, using: &g), height: .random(in: 4...60, using: &g)))
    }
    let out = NSMutableData()
    let d = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(d)
    return out as Data
}

func size(of data: Data) -> (Int, Int) {
    let s = CGImageSourceCreateWithData(data as CFData, nil)!
    let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as! [CFString: Any]
    return (p[kCGImagePropertyPixelWidth] as! Int, p[kCGImagePropertyPixelHeight] as! Int)
}

func botOut(_ mid: Int, _ text: String, buttons: [[(String, String)]] = [], edited: Bool = false, version: Int = 1,
            ts: Int = 1_700_000_000) -> Envelope {
    Envelope(type: .chatOut, op: .upsert, id: "m\(mid)", version: version, updatedAt: ts, data: .object([
        "mid": .number(Double(mid)), "text": .string(text), "ts": .number(Double(ts)), "edited": .bool(edited),
        "buttons": .array(buttons.map { .array($0.map { .object(["text": .string($0.0), "data": .string($0.1)]) }) })]))
}

// MARK: Telegram HTML
@Test func htmlTagsEntitiesAndUnknownMarkup() {
    let h = "🍽 <b>Lunch</b> · <i>maybe</i> <code>x &lt; y &amp; z</code> <u>kept</u><br>2 &gt; 1"
    #expect(TelegramHTML.plain(h) == "🍽 Lunch · maybe x < y & z kept\n2 > 1")
    let a = TelegramHTML.attributed("a <b>b <i>c</i></b> d")
    let runs = a.runs.map { (String(a[$0.range].characters), $0.inlinePresentationIntent) }
    #expect(runs.map(\.0) == ["a ", "b ", "c", " d"])
    #expect(runs[1].1 == .stronglyEmphasized && runs[2].1 == [.stronglyEmphasized, .emphasized] && runs[3].1 == nil)
    #expect(TelegramHTML.plain("1 < 2 and <b>unclosed") == "1 < 2 and unclosed")
    #expect(TelegramHTML.plain("<b>chicken &lt;b&gt;</b>") == "chicken <b>")
}

// MARK: photo resize
@Test func bigPhotoIsShrunkToTheLimitsAndStripsNothingVisible() throws {
    let big = testImage(width: 3000, height: 2000)
    let r = try #require(PhotoPrep.resize(big))
    #expect(max(r.width, r.height) <= PhotoPrep.maxSide && r.jpeg.count <= PhotoPrep.maxBytes)
    #expect(r.jpeg.count < big.count && r.originalBytes == big.count)
    let (w, h) = size(of: r.jpeg)
    #expect(w == r.width && h == r.height && abs(Double(w) / Double(h) - 1.5) < 0.02)    // aspect kept
}

@Test func smallPhotoIsNeverUpscaledAndPngBecomesJpeg() throws {
    let small = testImage(width: 300, height: 200)
    let r = try #require(PhotoPrep.resize(small))
    #expect(r.width == 300 && r.height == 200)
    let png = testImage(width: 500, height: 500, type: .png, alpha: true)
    let p = try #require(PhotoPrep.resize(png))
    #expect(p.jpeg.prefix(2) == Data([0xFF, 0xD8]))                                      // JPEG magic
}

@Test func tightByteBudgetLowersQualityThenSize() throws {
    let r = try #require(PhotoPrep.resize(testImage(width: 3000, height: 2000), maxBytes: 60_000))
    #expect(r.jpeg.count <= 60_000 || max(r.width, r.height) <= 700)
    #expect(PhotoPrep.resize(Data("not an image".utf8)) == nil)
    let t = try #require(PhotoPrep.thumbnail(testImage(width: 2000, height: 1000)))
    #expect(max(size(of: t).0, size(of: t).1) <= 480)
}

@Test func chunksCoverTheBytesExactly() {
    let d = Data((0..<250_000).map { UInt8($0 % 251) })
    let c = PhotoPrep.chunks(d, size: ChatWire.chunkSize)
    #expect(c.count == 7 && c.dropLast().allSatisfy { $0.count == ChatWire.chunkSize })
    #expect(c.reduce(Data(), +) == d)
    #expect(PhotoPrep.chunks(Data(), size: 10).isEmpty)
}

@Test func everyChunkFitsTheRelaysRecordLimit() throws {
    let full = Data((0..<ChatWire.chunkSize).map { _ in UInt8.random(in: 0...255) })
    let c = try #require(ChatWire.photoChunks(photoID: UUID().uuidString.lowercased(), jpeg: full).first)
    let env = Envelope(type: c.type, op: .upsert, id: c.id, version: Int(Date().timeIntervalSince1970 * 1000),
                       updatedAt: 1_700_000_000, data: c.data)
    let sealed = try RecordCrypto.seal(env.encoded(), key: K, deviceID: "phone-device-id", recordID: "AAAAAAAAAAAAAAAAAAAAAA")
    #expect(sealed.ciphertext.count <= 87_384, "relay MAX_CIPHERTEXT_B64")
    #expect(c.id.count <= 128)
}

// MARK: store
@Test func botMessagesEditInPlaceAndDeliveryTicksAdvance() async {
    let s = ChatStore(directory: tempDir())
    let me = await s.addUser(text: "/today", photos: [])
    #expect(me.delivery == .sending)
    await s.markSent()
    var snap = await s.snapshot()
    #expect(snap.messages[0].delivery == .sent && snap.awaitingReply)

    await s.apply(botOut(7, "🔍 Analysing…"))
    snap = await s.snapshot()
    #expect(snap.messages.map(\.id) == [me.id, "m7"] && snap.messages[0].delivery == .answered && !snap.awaitingReply)

    await s.apply(botOut(7, "<b>Done</b>", buttons: [[("Save", "save:1"), ("Discard", "del:1")]], edited: true, version: 2, ts: 1_700_000_500))
    snap = await s.snapshot()
    #expect(snap.messages.count == 2 && snap.messages[1].text == "<b>Done</b>" && snap.messages[1].edited)
    #expect(snap.messages[1].buttons == [[ChatButton(text: "Save", data: "save:1"), ChatButton(text: "Discard", data: "del:1")]])
    #expect(snap.messages[1].date == Date(timeIntervalSince1970: 1_700_000_000))        // an edit keeps its place and time
    #expect(snap.messages[1].mid == 7)
}

@Test func typingToastAndUnreadCount() async {
    let s = ChatStore(directory: tempDir())
    let soon = Date().timeIntervalSince1970 + 5
    await s.apply(Envelope(type: .chatOut, op: .upsert, id: "typing", version: 1, updatedAt: 0, data: .object(["typing_until": .number(soon)])))
    var snap = await s.snapshot()
    #expect(snap.isTyping())
    await s.apply(Envelope(type: .chatOut, op: .upsert, id: "toast", version: 1, updatedAt: 0, data: .object(["toast": .string("Saved ✓")])))
    snap = await s.snapshot()
    let again = await s.snapshot()
    #expect(snap.toast == "Saved ✓" && again.toast == nil)                                    // shown once

    await s.apply(botOut(1, "a", ts: Int(Date().timeIntervalSince1970) + 1))
    await s.apply(botOut(2, "b", ts: Int(Date().timeIntervalSince1970) + 1))
    snap = await s.snapshot()
    #expect(snap.unread == 2 && !snap.isTyping())                                            // a reply ends "typing…"
    await s.markRead(now: Date().addingTimeInterval(10))
    snap = await s.snapshot()
    #expect(snap.unread == 0)
}

@Test func malformedOutEnvelopesAreIgnoredAndStoreSurvivesRestart() async {
    let dir = tempDir()
    let s = ChatStore(directory: dir)
    await s.apply(Envelope(type: .chatOut, op: .upsert, id: "m1", version: 1, updatedAt: 0, data: .object(["text": .string("no mid")])))
    await s.apply(Envelope(type: .chatOut, op: .delete, id: "m2", version: 1, updatedAt: 0))
    await s.apply(weight("w", 1, 80))
    var first = await s.snapshot()
    #expect(first.messages.isEmpty)
    await s.apply(botOut(3, "kept"))
    let name = await s.savePhoto(jpeg: Data([1, 2, 3]), thumbnail: Data([4]))
    await s.addUser(text: "pic", photos: [name])

    let reopened = ChatStore(directory: dir)
    first = await reopened.snapshot()
    #expect(first.messages.map(\.text) == ["kept", "pic"] && first.messages[1].photos == [name])
    #expect((try? Data(contentsOf: reopened.mediaURL(name))) == Data([1, 2, 3]))
}

@Test func removeClearAndPruneDeleteTheirPhotos() async {
    let s = ChatStore(directory: tempDir())
    let a = await s.savePhoto(jpeg: Data([1]), thumbnail: Data([1])), b = await s.savePhoto(jpeg: Data([2]), thumbnail: nil)
    let m = await s.addUser(text: "one", photos: [a])
    await s.addUser(text: "two", photos: [b])
    await s.remove(id: m.id)
    #expect(!FileManager.default.fileExists(atPath: s.mediaURL(a).path) && !FileManager.default.fileExists(atPath: s.mediaURL(a, thumbnail: true).path))
    await s.clear()
    let cleared = await s.snapshot()
    #expect(cleared.messages.isEmpty && !FileManager.default.fileExists(atPath: s.mediaURL(b).path))
    for i in 0..<(ChatStore.maxMessages + 25) { await s.apply(botOut(i + 1, "m\(i)")) }
    let snap = await s.snapshot()
    #expect(snap.messages.count == ChatStore.maxMessages && snap.messages.last?.text == "m\(ChatStore.maxMessages + 24)")
}

// MARK: through the sync engine
@Test func chatInGoesOutInOrderAndChatOutComesBackWithoutHealthKit() async throws {
    let relay = FakeRelay(device: "phone"), state = InMemoryStateStore(), chat = ChatStore(directory: tempDir())
    let sink = ChatOnlySink(chat: chat)
    let engine = SyncEngine(deviceID: "phone", key: K, relay: relay, store: state, sink: sink)

    let pid = UUID().uuidString.lowercased()
    let photo = Data((0..<90_000).map { _ in UInt8.random(in: 0...255) })
    for c in ChatWire.photoChunks(photoID: pid, jpeg: photo) + [ChatWire.message(text: "rice", photoIDs: [pid])] { await state.enqueue(c) }
    let r1 = try await engine.cycle()
    let left = await state.pending()
    #expect(r1.pushed == 4 && left.isEmpty)

    var kinds: [String] = [], got = Data()
    for row in await relay.rows {
        let env = try Envelope.decode(RecordCrypto.open(nonce: row.rec.nonce, ciphertext: row.rec.ciphertext, key: K, deviceID: "phone", recordID: row.rec.recordID))
        #expect(env.type == .chatIn)
        kinds.append(env.data?["kind"]?.stringValue ?? "?")
        if let b = env.data?["b64"]?.stringValue { got.append(Data(base64Encoded: b)!) }
    }
    #expect(kinds == ["photo", "photo", "photo", "message"] && got == photo)             // chunks first, the message last

    try await relay.inject(device: "mac", id: "mac-rec-0001", env: botOut(1, "hello"), key: K)
    let r2 = try await engine.cycle()
    let after = await chat.snapshot()
    #expect(r2.pulled == 1 && after.messages.map(\.text) == ["hello"])
}

struct ChatOnlySink: InboundSink {
    let chat: ChatStore
    func apply(_ env: Envelope) async throws { if env.type == .chatOut { await chat.apply(env) } }
}

@Test func largePushIsSplitByBodySizeNotJustRecordCount() async throws {
    let t = MockTransport()
    let c = try RelayClient(url: "https://r.example", token: "dev.secret", transport: t)
    let big = String(repeating: "A", count: 70_000)
    let recs = (0..<30).map { RecordCrypto.Sealed(recordID: "rec-\(String(format: "%05d", $0))", nonce: "AAAA", ciphertext: big) }
    try await c.push(recs)
    #expect(t.requests.count > 1)
    #expect(t.requests.allSatisfy { ($0.httpBody?.count ?? 0) < 800_000 })
    let sent = try t.requests.flatMap { r -> [[String: Any]] in
        (try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any])["records"] as! [[String: Any]] }
    #expect(sent.count == 30 && sent.map { $0["record_id"] as! String } == recs.map(\.recordID))   // all of them, in order
}

// MARK: status
@Test func presenceIsRecordedAndNeverShownAsAMessage() async {
    let s = ChatStore(directory: tempDir())
    var snap = await s.snapshot()
    #expect(snap.heardAt == nil && snap.aiReady == nil)
    await s.apply(Envelope(type: .chatOut, op: .upsert, id: "presence", version: 1, updatedAt: 0,
                           data: .object(["ts": .number(1), "ai": .bool(false)])))
    snap = await s.snapshot()
    #expect(snap.messages.isEmpty && snap.aiReady == false && snap.heardAt != nil)
    await s.apply(Envelope(type: .chatOut, op: .upsert, id: "presence", version: 2, updatedAt: 0,
                           data: .object(["ts": .number(2), "ai": .null])))
    snap = await s.snapshot()
    #expect(snap.aiReady == nil)
}

@Test func headerStatusFollowsWhatWasHeardFromTheMac() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func chat(heard: TimeInterval? = nil, ai: Bool? = nil, typing: Bool = false, waiting: Bool = false) -> ChatSnapshot {
        var c = ChatSnapshot()
        c.heardAt = heard.map { now.addingTimeInterval($0) }; c.aiReady = ai
        if typing { c.typingUntil = now.addingTimeInterval(4) }
        if waiting { c.messages = [ChatMessage(id: "u", role: .user, text: "hi", date: now.addingTimeInterval(-10), delivery: .sent)] }
        return c
    }
    func status(_ c: ChatSnapshot, ping: TimeInterval? = nil, relay: Bool = true, at: TimeInterval = 0) -> ChatStatus {
        ChatStatus.derive(chat: c, pingSentAt: ping.map { now.addingTimeInterval($0) }, relayOK: relay, now: now.addingTimeInterval(at))
    }
    #expect(status(chat(), relay: false) == .offline)                                  // beats everything
    #expect(status(chat(), ping: 0, at: 5) == .checking)                               // asked, no answer yet
    #expect(status(chat(), ping: 0, at: 30) == .macUnreachable)                        // Mac asleep
    #expect(status(chat(heard: 3, ai: true), ping: 0, at: 5) == .online(aiReady: true))
    #expect(status(chat(heard: 3, ai: false), ping: 0, at: 5) == .online(aiReady: false))
    #expect(status(chat(heard: -20, ai: true), ping: -1, at: 0) == .online(aiReady: true))   // recent contact: no flicker while re-pinging
    #expect(status(chat(heard: -100, ai: true), ping: -1, at: 0) == .checking)               // contact is stale: wait for the answer
    #expect(status(chat(heard: 3), ping: 0, at: 5) == .online(aiReady: nil))           // AI state unknown
    #expect(status(chat(typing: true, waiting: true), ping: 0, at: 2) == .working)
    #expect(status(chat(heard: 2, waiting: true), ping: 0, at: 5) == .waiting)         // alive, answer pending
    #expect(status(chat(waiting: true), at: 40) == .macUnreachable)                    // message sent, nothing came back
    #expect(status(chat(heard: -60, ai: true)) == .online(aiReady: true))              // fresh enough with no ping
    #expect(status(chat(heard: 3, ai: true), ping: 0, at: 500) == .online(aiReady: true))   // answered pings stay answered
    #expect(status(chat(heard: -200), at: 0) == .checking)                             // stale: must ask
}

@Test func pingWireShape() {
    let p = ChatWire.ping()
    #expect(p.type == .chatIn && p.data?["kind"]?.stringValue == "ping" && p.id.hasPrefix("g-"))
}

@Test func aFinalEditEndsTypingToo() async {
    let s = ChatStore(directory: tempDir())
    await s.apply(botOut(5, "🔍 Analysing…"))
    await s.apply(Envelope(type: .chatOut, op: .upsert, id: "typing", version: 1, updatedAt: 0,
                           data: .object(["typing_until": .number(Date().timeIntervalSince1970 + 6)])))
    var snap = await s.snapshot()
    #expect(snap.isTyping())
    await s.apply(botOut(5, "<b>Lunch</b> 458 kcal", edited: true, version: 2))
    snap = await s.snapshot()
    #expect(!snap.isTyping())
}

@Test func gaugesAreParsedKeptOnEditAndOldChatsStillLoad() async throws {
    let dir = tempDir()
    let s = ChatStore(directory: dir)
    var env = botOut(1, "Today")
    env.data = .object(["mid": .number(1), "text": .string("Today"), "ts": .number(1_700_000_000), "visuals": .array([
        .object(["type": .string("gauge"), "label": .string("Calories"), "value": .number(2300), "max": .number(2000),
                 "unit": .string("kcal"), "status": .string("over")]),
        .object(["type": .string("gauge"), "label": .string("bad"), "value": .number(1), "max": .number(0)]),
        .object(["type": .string("pie")])])])
    await s.apply(env)
    let v = await s.snapshot().messages[0].visuals
    #expect(v == [ChatVisual(label: "Calories", value: 2300, max: 2000, unit: "kcal", status: .over)])
    #expect(v?[0].fraction == 1)
    await s.apply(botOut(1, "Today", edited: true, version: 2))      // an edit without visuals clears them
    #expect(await s.snapshot().messages[0].visuals == nil)
    let old = #"{"id":"m9","role":"bot","text":"x","buttons":[],"date":0,"edited":false,"photos":[],"delivery":"answered"}"#
    #expect(try JSONDecoder().decode(ChatMessage.self, from: Data(old.utf8)).visuals == nil)
}

@Test func chartsRingsAndTargetsAreParsedAndBadOnesDropped() async {
    let s = ChatStore(directory: tempDir())
    func pt(_ l: String, _ v: Double) -> JSONValue { .object(["label": .string(l), "value": .number(v)]) }
    var env = botOut(2, "Week")
    env.data = .object(["mid": .number(2), "text": .string("Week"), "ts": .number(1_700_000_000), "visuals": .array([
        .object(["type": .string("ring"), "label": .string("Calories"), "value": .number(500), "max": .number(2000), "status": .string("ok")]),
        .object(["type": .string("bars"), "label": .string("Steps"), "points": .array([pt("Mon", 4000), pt("Tue", 9000)]), "target": .number(8000)]),
        .object(["type": .string("line"), "label": .string("Weight"), "unit": .string("kg"), "points": .array([pt("1", 80), pt("2", 79.5), .object(["label": .string("bad")])])]),
        .object(["type": .string("bars"), "label": .string("one point"), "points": .array([pt("a", 1)])])])])
    await s.apply(env)
    let v = await s.snapshot().messages[0].visuals ?? []
    #expect(v.map(\.kind) == [.ring, .bars, .line])
    #expect(v[0].fraction == 0.25 && v[1].target == 8000 && v[1].points.count == 2 && v[2].points.count == 2 && v[2].unit == "kg")
    let enc = try! JSONEncoder().encode(v), back = try! JSONDecoder().decode([ChatVisual].self, from: enc)
    #expect(back == v)
    let oldGauge = #"[{"label":"Calories","value":1,"max":2,"unit":"kcal"}]"#      // saved by the first build: no kind
    #expect(try! JSONDecoder().decode([ChatVisual].self, from: Data(oldGauge.utf8)).first?.kind == .gauge)
}
