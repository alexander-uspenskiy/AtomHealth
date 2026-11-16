import SwiftUI

struct ContentView: View {
    @State private var model = AppModel.shared
    @State private var code = ""
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.phase == .unpaired {
                NavigationStack {
                    Form {
                        pairing
                        if let e = model.error { Section { Text(e).foregroundStyle(.red).font(.footnote) } }
                    }
                    .navigationTitle("Atom Health")
                }
            } else {
                TabView(selection: Binding(get: { model.tab }, set: { model.tab = $0 })) {
                    OverviewView(model: model).toolbar(.hidden, for: .tabBar).tag(AppModel.Tab.overview)
                    ChatView(model: model).toolbar(.hidden, for: .tabBar).tag(AppModel.Tab.chat)
                    NavigationStack {
                        Form {
                            synced
                            if let e = model.error { Section { Text(e).foregroundStyle(.red).font(.footnote) } }
                        }
                        .navigationTitle("Sync")
                        .appTabBar(model)
                    }
                    .toolbar(.hidden, for: .tabBar).tag(AppModel.Tab.sync)
                }
                .tint(Theme.accent)
            }
        }
        .task { await model.start() }
        // Probe the Mac for as long as the app is open, so the status is already known when the chat is opened:
        // "are you there?" every 40 s (every 5 min while it is not answering).
        .task(id: "\(scenePhase)-\(model.phase == .paired)") {
            guard scenePhase == .active, model.phase == .paired else { return }
            var last = Date.distantPast
            while !Task.isCancelled {
                let every: TimeInterval = model.chatStatus() == .macUnreachable ? 300 : 40
                if Date().timeIntervalSince(last) >= every { last = Date(); await model.pingMac() }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onChange(of: scenePhase) { _, p in if p == .active { Task { await model.syncNow() } } }
    }

    var pairing: some View {
        Section("Pair with your Mac") {
            Text("On the Mac run `python -m atomhealth.relay pair-phone`, then paste the code here.").font(.footnote)
            TextField("ahpair1:…", text: $code, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.system(.footnote, design: .monospaced)).lineLimit(3...6)
            Button("Paste from clipboard") { code = UIPasteboard.general.string ?? "" }
            Button("Pair") {
                model.pair(code: code)
                if model.phase == .paired { code = ""; UIPasteboard.general.string = ""; Task { await model.start() } }
            }.disabled(code.isEmpty)
        }
    }

    @ViewBuilder var synced: some View {
        Section("Status") {
            LabeledContent("State", value: model.status)
            LabeledContent("Last sync", value: model.lastSync.map { $0.formatted(.relative(presentation: .named)) } ?? "never")
            LabeledContent("Waiting to send", value: "\(model.pending)")
            if let r = model.lastReport {
                LabeledContent("Last cycle", value: "in \(r.pulled), out \(r.pushed), skipped \(r.stale + r.bad)")
            }
            Button(model.busy ? "Syncing…" : "Sync now") { Task { await model.syncNow() } }.disabled(model.busy)
        }
        Section {
            Button("Unpair this phone", role: .destructive) { model.unpair() }
        } footer: { Text("Removes the token and data key from this phone. Health data stays where it is.") }
    }
}

/// Bottom bar: Overview and Sync on the sides, Chat as a raised gradient circle in the middle (with the unread count).
struct AppTabBar: View {
    let model: AppModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            item(.overview, "Overview", "heart.text.square.fill")
            chat
            item(.sync, "Sync", "arrow.triangle.2.circlepath")
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func item(_ tab: AppModel.Tab, _ title: String, _ icon: String) -> some View {
        let on = model.tab == tab
        return Button { model.tab = tab } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 22)).frame(height: 28)
                Text(title).font(.caption2.weight(on ? .bold : .medium))
            }
            .foregroundStyle(on ? Theme.accent : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
    }

    private var chat: some View {
        let on = model.tab == .chat
        return Button { model.tab = .chat } label: {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 28)).foregroundStyle(.white)
                        .frame(width: 66, height: 66)
                        .background(LinearGradient(colors: [Color(hex: 0x4F46E5), Color(hex: 0x7C3AED)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                        .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: on ? 5 : 3))
                        .shadow(color: Theme.accent.opacity(on ? 0.55 : 0.35), radius: on ? 12 : 8, y: 4)
                        .overlay(alignment: .bottomTrailing) {      // is the Mac there? (green / grey / orange / red)
                            TimelineView(.periodic(from: .now, by: 3)) { ctx in
                                Circle().fill(model.chatStatus(at: ctx.date).color).frame(width: 18, height: 18)
                                    .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 3))
                            }
                            .offset(x: 1, y: 1).accessibilityHidden(true)
                        }
                    if model.tab != .chat, model.chat.unread > 0 {
                        Text("\(model.chat.unread)").font(.caption.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 2).background(Color.red, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color(.systemBackground), lineWidth: 2)).offset(x: 6, y: -4)
                            .accessibilityLabel("\(model.chat.unread) unread")
                    }
                }
                .offset(y: -18).padding(.bottom, -18)
                Text("Chat").font(.caption2.weight(.bold)).foregroundStyle(Theme.accent)
            }
            .frame(width: 96).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel("Chat").accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Puts the bar at the bottom of one screen. It has to be applied per screen (an inset on the TabView does not reach
/// the screens inside it, so the chat's message field would end up under the bar) and it hides while the keyboard is up.
struct TabBarInset: ViewModifier {
    let model: AppModel
    @State private var keyboardUp = false
    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) { if !keyboardUp { AppTabBar(model: model) } }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
    }
}

extension View {
    func appTabBar(_ model: AppModel) -> some View { modifier(TabBarInset(model: model)) }
}
