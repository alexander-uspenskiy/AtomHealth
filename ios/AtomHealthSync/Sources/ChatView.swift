import AtomHealthCore
import PhotosUI
import SwiftUI

/// What the bot understands, for the "/" menu and the suggestions above the keyboard.
struct BotCommand: Identifiable {
    let cmd: String, hint: String, detail: String
    var needsArgument: Bool { !hint.isEmpty }
    var id: String { cmd }
    static let all = [
        BotCommand(cmd: "/today", hint: "", detail: "Today's dishes, calories and advice"),
        BotCommand(cmd: "/history", hint: "", detail: "Meals of the last 12 hours"),
        BotCommand(cmd: "/advice", hint: "", detail: "Coaching tip for today"),
        BotCommand(cmd: "/week", hint: "", detail: "Weekly review and calorie-target check"),
        BotCommand(cmd: "/ask", hint: "question", detail: "Ask the coach about your diet"),
        BotCommand(cmd: "/edit", hint: "# what it really was", detail: "Correct a meal (last 12 h)"),
        BotCommand(cmd: "/delete", hint: "#", detail: "Delete a meal (last 12 h)"),
        BotCommand(cmd: "/undo", hint: "", detail: "Delete the last meal with its photos"),
        BotCommand(cmd: "/weight", hint: "", detail: "Your latest weight"),
        BotCommand(cmd: "/help", hint: "", detail: "What the bot can do"),
    ]
}

/// A photo the user picked: shown at once, resized in the background, sent with the next message.
struct StagedPhoto: Identifiable {
    let id = UUID()
    var result: PhotoPrep.Result?
    var preview: UIImage?
    var failed = false
    var preparing: Bool { result == nil && !failed }
}

/// The Chat tab: the same bot as Telegram (meal photos, commands, buttons, coaching), over the encrypted relay.
struct ChatView: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft = ""
    @State private var staged: [StagedPhoto] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPicker = false
    @State private var showCamera = false
    @State private var showCommands = false
    @State private var confirmClear = false
    @State private var viewer: ViewerRequest?
    @State private var toast: String?
    @State private var tapped: [String: Date] = [:]
    @FocusState private var focused: Bool

    private var chat: ChatSnapshot { model.chat }
    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool { (!trimmed.isEmpty || staged.contains { $0.result != nil }) && !staged.contains { $0.preparing } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                messages
                TimelineView(.periodic(from: .now, by: 2)) { ctx in
                    if let note = connectionNote(at: ctx.date) {
                        Text(note).font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
                    }
                }
                suggestions
                tray
                composer
            }
            .background(Color(.systemGroupedBackground))
            .overlay(alignment: .top) { toastView }
            .navigationTitle("Coach").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { header }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showCommands = true } label: { Label("Commands", systemImage: "slash.circle") }
                        Button(role: .destructive) { confirmClear = true } label: { Label("Clear chat on this phone", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .confirmationDialog("Clear the whole chat on this phone?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear chat", role: .destructive) { Task { await model.clearChat() } }
            } message: { Text("Meals and data on your Mac are not affected.") }
            .sheet(isPresented: $showCommands) { commandsSheet }
            .fullScreenCover(item: $viewer) { PhotoViewer(request: $0) }
            .fullScreenCover(isPresented: $showCamera) { CameraPicker { addPhotos([$0]) }.ignoresSafeArea() }
            .photosPicker(isPresented: $showPicker, selection: $pickerItems,
                          maxSelectionCount: max(1, ChatWire.maxPhotos - staged.count), matching: .images)
            .onChange(of: pickerItems) { _, items in loadPicked(items) }
            .onChange(of: chat.toast) { _, t in if let t { flash(t) } }
            .onChange(of: chat.messages.count) { _, _ in Task { await model.markChatRead() } }
            .task(id: scenePhase) { await poll() }
        }
    }

    // MARK: polling
    /// While the tab is open the app checks the relay every few seconds (faster while an answer is pending) and asks the
    /// Mac "are you there?" on opening and then every ~40 s (every 5 min while it is not answering).
    private func poll() async {
        guard scenePhase == .active else { return }
        await model.markChatRead()
        var lastPing = Date.distantPast
        while !Task.isCancelled {
            let every: TimeInterval = status() == .macUnreachable ? 300 : 40
            if Date().timeIntervalSince(lastPing) >= every { lastPing = Date(); await model.pingMac() }
            else { await model.syncNow(health: false) }
            let waiting = model.chat.awaitingReply || model.chat.isTyping()
            try? await Task.sleep(for: .seconds(waiting ? 1.5 : 4))
        }
    }

    // MARK: header and status
    /// The status depends on the clock ("no answer for 25 s"), and SwiftUI does not redraw when nothing observable
    /// changed (a dead Mac sends nothing), so the views that show it re-evaluate on a timer.
    private func status(at now: Date = Date()) -> ChatStatus {
        ChatStatus.derive(chat: chat, pingSentAt: model.pingSentAt, relayOK: model.relayOK, now: now)
    }

    private var header: some View {
        TimelineView(.periodic(from: .now, by: 2)) { ctx in
            let s = presentation(status(at: ctx.date))
            VStack(spacing: 1) {
                Text("Coach").font(.headline)
                HStack(spacing: 5) {
                    Circle().fill(s.color).frame(width: 7, height: 7)
                    Text(s.label).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func presentation(_ s: ChatStatus) -> (label: String, color: Color) {
        switch s {
        case .offline: ("No connection", .red)
        case .checking: ("Checking your Mac…", .gray)
        case .macUnreachable: ("Mac not responding", .orange)
        case .waiting: ("Waiting for the answer…", Theme.accent)
        case .working: ("Working…", Theme.accent)
        case .online(let ai): ai == false ? ("Online · AI offline", .orange) : ("Online", Theme.good)
        }
    }

    /// A line under the messages when something needs explaining.
    private func connectionNote(at now: Date = Date()) -> String? {
        switch status(at: now) {
        case .offline:
            model.status.hasPrefix("Device revoked") ? "This phone was revoked. Pair it again."
                : "No connection. Messages are sent when you are back online."
        case .macUnreachable:
            "Your Mac is not responding. It may be asleep or offline; it will answer when it is back."
        case .online(let ai) where ai == false:
            "The AI model on your Mac is not reachable: commands work, but meal photos and coaching will fail."
        default: nil
        }
    }

    @ViewBuilder private var toastView: some View {
        if let toast {
            Text(toast).font(.subheadline.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule()).padding(.top, 8).transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func flash(_ text: String) {
        withAnimation { toast = text }
        Task { try? await Task.sleep(for: .seconds(2)); withAnimation { toast = nil } }
    }

    // MARK: messages
    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if chat.messages.isEmpty { emptyState }
                    ForEach(Array(chat.messages.enumerated()), id: \.element.id) { i, m in
                        if i == 0 || !Calendar.current.isDate(m.date, inSameDayAs: chat.messages[i - 1].date) { DaySeparator(date: m.date) }
                        MessageBubble(message: m, model: model, tapsDisabled: isBusy(m), onPhoto: { viewer = $0 },
                                      onButton: { b in press(m, b) }, onDelete: { Task { await model.deleteChatMessage(m.id) } })
                            .id(m.id)
                    }
                    if chat.isTyping() { TypingBubble().id("typing") }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 12).padding(.top, 4)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chat.messages.last?.id) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: chat.messages.last?.text) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: chat.isTyping()) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: focused) { _, f in if f { withAnimation { proxy.scrollTo("end", anchor: .bottom) } } }
        }
    }

    /// A button stays disabled from the tap until the bot edits that message (or 20 s pass).
    private func isBusy(_ m: ChatMessage) -> Bool {
        guard let t = tapped[m.id + "|" + m.text] else { return false }
        return Date().timeIntervalSince(t) < 20
    }

    private func press(_ m: ChatMessage, _ b: ChatButton) {
        tapped[m.id + "|" + m.text] = Date()
        Task { await model.tapChatButton(m, b) }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "fork.knife.circle.fill").font(.system(size: 48)).foregroundStyle(Theme.accent)
            Text("Your AtomHealth coach").font(.title3.weight(.semibold))
            Text("Send a photo of your meal, describe it in words, or ask a question. It works like the Telegram bot.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                ForEach(["/start", "/today"], id: \.self) { c in
                    Button(c) { Task { await model.sendChat(text: c) } }.buttonStyle(.bordered)
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 60).frame(maxWidth: .infinity)
    }

    // MARK: composer
    @ViewBuilder private var suggestions: some View {
        let t = trimmed
        if t.hasPrefix("/"), !t.contains(" ") {
            let matches = BotCommand.all.filter { $0.cmd.hasPrefix(t.lowercased()) && $0.cmd != t.lowercased() }
            if !matches.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { ForEach(matches) { c in Button(c.cmd) { choose(c) }.buttonStyle(.bordered).controlSize(.small) } }
                        .padding(.horizontal, 12)
                }
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder private var tray: some View {
        if !staged.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(staged) { p in
                            ZStack(alignment: .topTrailing) {
                                Group {
                                    if let img = p.preview { Image(uiImage: img).resizable().scaledToFill() } else { Rectangle().fill(.quaternary) }
                                }
                                .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay { if p.preparing { ProgressView() } else if p.failed { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) } }
                                Button { staged.removeAll { $0.id == p.id } } label: {
                                    Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.65))
                                }
                                .offset(x: 5, y: -5).accessibilityLabel("Remove photo")
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.top, 6)
                }
                Text(trayInfo).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 12)
            }
            .padding(.bottom, 4)
        }
    }

    private var trayInfo: String {
        let ready = staged.compactMap(\.result)
        if staged.contains(where: \.failed) { return "A photo could not be read and will be skipped." }
        if ready.count < staged.count { return "Resizing…" }
        let now = ready.reduce(0) { $0 + $1.jpeg.count }, was = ready.reduce(0) { $0 + $1.originalBytes }
        let f = ByteCountFormatter()
        return "\(ready.count) photo\(ready.count == 1 ? "" : "s") resized for sending: \(f.string(fromByteCount: Int64(now))) (was \(f.string(fromByteCount: Int64(was))))"
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                Button { showPicker = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                if CameraPicker.available { Button { showCamera = true } label: { Label("Take Photo", systemImage: "camera") } }
            } label: {
                Image(systemName: "paperclip").font(.title3).frame(width: 36, height: 36)
            }
            .disabled(staged.count >= ChatWire.maxPhotos).accessibilityLabel("Attach a photo")

            HStack(alignment: .bottom, spacing: 4) {
                TextField(staged.isEmpty ? "Message or /command" : "Add a caption (e.g. 200 g rice)", text: $draft, axis: .vertical)
                    .lineLimit(1...5).focused($focused).textInputAutocapitalization(.sentences)
                    .padding(.leading, 12).padding(.vertical, 8)
                if draft.isEmpty {
                    Button { showCommands = true } label: { Image(systemName: "slash.circle").font(.title3).foregroundStyle(.secondary) }
                        .padding(.trailing, 8).padding(.bottom, 6).accessibilityLabel("Commands")
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 32)) }
                .foregroundStyle(canSend ? Theme.accent : Color.secondary.opacity(0.4)).disabled(!canSend).accessibilityLabel("Send")
        }
        .padding(.horizontal, 10).padding(.vertical, 8).background(.bar)
    }

    private var commandsSheet: some View {
        NavigationStack {
            List(BotCommand.all) { c in
                Button { showCommands = false; choose(c) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.cmd + (c.hint.isEmpty ? "" : " <\(c.hint)>")).font(.body.monospaced()).foregroundStyle(.primary)
                        Text(c.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Commands").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showCommands = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: actions
    private func choose(_ c: BotCommand) {
        if c.needsArgument { draft = c.cmd + " "; focused = true } else { draft = ""; Task { await model.sendChat(text: c.cmd) } }
    }

    private func send() {
        let text = trimmed, photos = staged.compactMap(\.result)
        guard canSend else { return }
        draft = ""; staged = []; pickerItems = []
        Task { await model.sendChat(text: text, photos: photos) }
    }

    private func loadPicked(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        pickerItems = []
        for item in items {
            let slot = StagedPhoto(); staged.append(slot)
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                await prepare(slot.id, data)
            }
        }
    }

    private func addPhotos(_ datas: [Data]) {
        for d in datas { let slot = StagedPhoto(); staged.append(slot); Task { await prepare(slot.id, d) } }
    }

    /// The resize runs off the main thread; a 12 MP photo takes a few hundred milliseconds.
    private func prepare(_ id: UUID, _ data: Data?) async {
        let out: (PhotoPrep.Result, Data)? = await Task.detached(priority: .userInitiated) {
            guard let data, let r = PhotoPrep.resize(data), let t = PhotoPrep.thumbnail(r.jpeg, maxSide: 160) else { return nil }
            return (r, t)
        }.value
        guard let i = staged.firstIndex(where: { $0.id == id }) else { return }
        if let (r, t) = out { staged[i].result = r; staged[i].preview = UIImage(data: t) } else { staged[i].failed = true }
    }
}
