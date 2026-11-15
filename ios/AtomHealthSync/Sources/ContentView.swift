import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()
    @State private var code = ""
    @State private var tab = Tab.overview
    enum Tab { case overview, chat, sync }
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.phase == .unpaired {
                NavigationStack {
                    Form {
                        pairing
                        if let e = model.error { Section { Text(e).foregroundStyle(.red).font(.footnote) } }
                    }
                    .navigationTitle("AtomHealth Sync")
                }
            } else {
                TabView(selection: $tab) {
                    OverviewView(model: model).tabItem { Label("Overview", systemImage: "heart.text.square") }.tag(Tab.overview)
                    ChatView(model: model).tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                        .badge(tab == .chat ? 0 : model.chat.unread).tag(Tab.chat)
                    NavigationStack {
                        Form {
                            synced
                            if let e = model.error { Section { Text(e).foregroundStyle(.red).font(.footnote) } }
                        }
                        .navigationTitle("Sync")
                    }
                    .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }.tag(Tab.sync)
                }
                .tint(Theme.accent)
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
