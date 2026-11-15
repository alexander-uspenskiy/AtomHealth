import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()
    @State private var code = ""
    @Environment(\.scenePhase) private var scenePhase
    @State private var keyboardUp = false

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
                            Section { ChatShortcut(model: model) }
                                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                            synced
                            if let e = model.error { Section { Text(e).foregroundStyle(.red).font(.footnote) } }
                        }
                        .navigationTitle("Sync")
                    }
                    .toolbar(.hidden, for: .tabBar).tag(AppModel.Tab.sync)
                }
                .tint(Theme.accent)
                // our own bar: Chat is the main action, so it is a raised round button in the middle
                .safeAreaInset(edge: .bottom, spacing: 0) { if !keyboardUp { AppTabBar(model: model) } }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
            }
        }
        .task { await model.start() }
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
