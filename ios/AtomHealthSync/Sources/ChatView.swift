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
    @State private var loadingEarlier = false
    @State private var fieldGeneration = 0          // bumping it rebuilds the text field (see `clearDraft`)
    @State private var topVisible = false           // the "loading" row at the top is on screen
    @State private var pagingArmed = false          // ignore the top row while the chat is still laying out and scrolling to the end
    @State private var showStorage = false
    @State private var bannerDismissed = false
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
                storageBanner
                suggestions
                tray
                composer
            }
            .background(Color(.systemGroupedBackground))
            .appTabBar(model)
            .overlay(alignment: .top) { toastView }
            .navigationTitle("Coach").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { focused = false; model.tab = .overview } label: { Label("Overview", systemImage: "chevron.left") }
                        .accessibilityLabel("Back to Overview")
                }
                ToolbarItem(placement: .principal) { header }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showCommands = true } label: { Label("Commands", systemImage: "slash.circle") }
                        Button { showStorage = true } label: { Label("Chat storage", systemImage: "internaldrive") }
                        Button(role: .destructive) { confirmClear = true } label: { Label("Clear chat on this phone", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .confirmationDialog("Clear the whole chat on this phone?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear chat", role: .destructive) { Task { await model.clearChat() } }
            } message: { Text("Meals and data on your Mac are not affected.") }
            .sheet(isPresented: $showCommands) { commandsSheet }
            .sheet(isPresented: $showStorage) { StorageSheet(model: model) }
            .fullScreenCover(item: $viewer) { PhotoViewer(request: $0) }
            .fullScreenCover(isPresented: $showCamera) { CameraPicker { addPhotos([$0]) }.ignoresSafeArea() }
            .photosPicker(isPresented: $showPicker, selection: $pickerItems,
                          maxSelectionCount: max(1, ChatWire.maxPhotos - staged.count), matching: .images)
            .onChange(of: pickerItems) { _, items in loadPicked(items) }
            .onChange(of: chat.toast) { _, t in if let t { flash(t) } }
            .onChange(of: chat.messages.count) { _, _ in Task { await model.markChatRead() } }
            .onChange(of: chat.total) { _, _ in Task { await model.refreshChatStorage() } }
            .task { await model.openChat(); try? await Task.sleep(for: .milliseconds(700)); pagingArmed = true }
            .task(id: scenePhase) { await poll() }
        }
    }

    // MARK: polling
    /// While the tab is open the app checks the relay every few seconds (faster while an answer is pending).
    private func poll() async {
        guard scenePhase == .active else { return }
        await model.markChatRead()
        // the app keeps probing the Mac while it is open; ask again on opening if the last answer is old
        if Date().timeIntervalSince(model.pingSentAt ?? .distantPast) > 20 { await model.pingMac() }
        while !Task.isCancelled {
            await model.syncNow(health: false)
            let waiting = model.chat.awaitingReply || model.chat.isTyping()
            try? await Task.sleep(for: .seconds(waiting ? 1.5 : 4))
        }
    }

    // MARK: header and status
    /// The status depends on the clock ("no answer for 25 s"), and SwiftUI does not redraw when nothing observable
    /// changed (a dead Mac sends nothing), so the views that show it re-evaluate on a timer.
    private func status(at now: Date = Date()) -> ChatStatus { model.chatStatus(at: now) }

    private var header: some View {
        TimelineView(.periodic(from: .now, by: 2)) { ctx in
            let s = status(at: ctx.date)
            VStack(spacing: 1) {
                HStack(spacing: 6) { BrandMark(size: 18); Text("Coach").font(.headline) }
                HStack(spacing: 5) {
                    Circle().fill(s.color).frame(width: 7, height: 7)
                    Text(s.label).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
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
                    if chat.hasEarlier {
                        // reaching the top of what is loaded brings in the next 10 (the view keeps its place)
                        ProgressView().controlSize(.small).padding(.vertical, 10).id("earlier")
                            .onAppear { topVisible = true; loadEarlier(proxy) }
                            .onDisappear { topVisible = false }
                    }
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

    private func loadEarlier(_ proxy: ScrollViewProxy) {
        guard pagingArmed, chat.hasEarlier, !loadingEarlier, let top = chat.messages.first?.id else { return }
        loadingEarlier = true
        Task {
            await model.loadEarlierChat()
            try? await Task.sleep(for: .milliseconds(60))
            proxy.scrollTo(top, anchor: .top)                // stay where you were: the older ones appear above
            try? await Task.sleep(for: .milliseconds(250))   // let the view settle
            loadingEarlier = false
            // onAppear fires once: if the row is still on screen (short pages, fast scrolling) ask for the next page now
            if topVisible { loadEarlier(proxy) }
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
            Menu { photoActions } label: {
                Label("Add a meal photo", systemImage: "camera.fill").font(.headline).padding(.horizontal, 22).padding(.vertical, 12)
                    .foregroundStyle(.white).background(Theme.accent, in: Capsule())
            }
            HStack {
                ForEach(["/start", "/today"], id: \.self) { c in
                    Button(c) { Task { await model.sendChat(text: c) } }.buttonStyle(.bordered)
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 60).frame(maxWidth: .infinity)
    }

    // MARK: storage
    /// Shown when the forecast says the archive will pass its limit soon (or already has): one tap cleans up.
    @ViewBuilder private var storageBanner: some View {
        if !bannerDismissed, let r = model.chatStorage, r.advice != .none {
            VStack(alignment: .leading, spacing: 6) {
                Text(r.summary).font(.caption).foregroundStyle(.primary)
                HStack {
                    if let o = model.chatCleanup {
                        Button("Delete \(o.messages) older than \(o.days) days (\(ChatStorageReport.size(o.bytes)))") {
                            Task { await model.cleanChat(olderThanDays: o.days) }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small).tint(r.advice == .full ? .red : Theme.accent)
                    }
                    Button("More…") { showStorage = true }.buttonStyle(.bordered).controlSize(.small)
                    Spacer()
                    Button { bannerDismissed = true } label: { Image(systemName: "xmark") }.foregroundStyle(.secondary)
                        .accessibilityLabel("Dismiss")
                }
            }
            .padding(10).background((r.advice == .full ? Color.red : Color.orange).opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 12).padding(.bottom, 4)
        }
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
            Menu { photoActions } label: {
                Image(systemName: "camera.fill").font(.system(size: 18)).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(Theme.accent, in: Circle())
            }
            .disabled(staged.count >= ChatWire.maxPhotos).accessibilityLabel("Attach a meal photo")

            HStack(alignment: .bottom, spacing: 4) {
                TextField(staged.isEmpty ? "Message or /command" : "Add a caption (e.g. 200 g rice)", text: $draft, axis: .vertical)
                    .lineLimit(1...5).focused($focused).textInputAutocapitalization(.sentences).id(fieldGeneration)
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

    /// The two ways to add a meal photo; shared by the camera button and the empty chat.
    @ViewBuilder private var photoActions: some View {
        if CameraPicker.available { Button { showCamera = true } label: { Label("Take a meal photo", systemImage: "camera") } }
        Button { showPicker = true } label: { Label("Choose from library", systemImage: "photo.on.rectangle") }
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
        if c.needsArgument { draft = c.cmd + " "; focused = true } else { clearDraft(); Task { await model.sendChat(text: c.cmd) } }
    }

    private func send() {
        let text = trimmed, photos = staged.compactMap(\.result)
        guard canSend else { return }
        staged = []; pickerItems = []
        clearDraft()
        Task { await model.sendChat(text: text, photos: photos) }
    }

    /// A multi-line field ignores being emptied while the keyboard still holds an unfinished (auto-corrected) word, so the
    /// sent text stayed in the box. Emptying it and rebuilding the field clears the keyboard's state too.
    private func clearDraft() {
        let hadFocus = focused
        draft = ""
        fieldGeneration += 1
        Task { @MainActor in
            draft = ""
            if hadFocus { focused = true }
        }
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

extension ChatStatus {
    var label: String {
        switch self {
        case .offline: "No connection"
        case .checking: "Checking your Mac…"
        case .macUnreachable: "Mac not responding"
        case .waiting: "Waiting for the answer…"
        case .working: "Working…"
        case .online(let ai): ai == false ? "Online · AI offline" : "Online"
        }
    }
    var color: Color {
        switch self {
        case .offline: .red
        case .checking: .gray
        case .macUnreachable: .orange
        case .waiting, .working: Theme.accent
        case .online(let ai): ai == false ? .orange : Theme.good
        }
    }
}

/// Chat storage: what is used, the forecast, and clean-up by age.
struct StorageSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirm: Int?

    var body: some View {
        NavigationStack {
            List {
                if let r = model.chatStorage {
                    Section {
                        row("Used", ChatStorageReport.size(r.usedBytes))
                        row("Messages", "\(r.messages)")
                        row("Limit", ChatStorageReport.size(ChatStorageReport.budgetBytes))
                        ProgressTrack(value: r.fraction, color: r.advice == .none ? Theme.accent : (r.advice == .full ? .red : .orange))
                        if r.bytesPerDay >= 1_000 { row("Recent growth", "\(ChatStorageReport.size(Int(r.bytesPerDay))) / day") }
                        if let d = r.daysLeft, r.bytesPerDay >= 1_000 { row("Limit reached in", d == 0 ? "now" : "~\(d) days") }
                    } footer: { Text("Photos take almost all of it. Meals and data on your Mac are not affected.") }
                    Section("Delete old messages") {
                        ForEach([7, 30, 90], id: \.self) { days in
                            Button("Older than \(days) days") { confirm = days }.disabled(isEmpty(days))
                        }
                    }
                }
            }
            .navigationTitle("Chat storage").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await model.refreshChatStorage() }
            .confirmationDialog("Delete messages older than \(confirm ?? 0) days?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) { if let d = confirm { Task { await model.cleanChat(olderThanDays: d) } }; confirm = nil }
            } message: { Text("With their photos, from this phone only. This cannot be undone.") }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundStyle(.secondary).monospacedDigit() }
    }

    private func isEmpty(_ days: Int) -> Bool { (model.chatStorage?.oldest).map { Date().timeIntervalSince($0) < Double(days) * 86_400 } ?? true }
}
