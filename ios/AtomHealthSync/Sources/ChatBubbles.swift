import AtomHealthCore
import SwiftUI
import UIKit

/// Decoded previews, so scrolling a long chat does not re-read files.
enum ChatImages {
    nonisolated(unsafe) static let cache = NSCache<NSString, UIImage>()
    static func image(at url: URL) -> UIImage? {
        let key = url.path as NSString
        if let i = cache.object(forKey: key) { return i }
        guard let i = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(i, forKey: key); return i
    }
}

enum ChatFormat {
    static func day(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }
    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
}

struct DaySeparator: View {
    let date: Date
    var body: some View {
        Text(ChatFormat.day(date)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color(.secondarySystemFill), in: Capsule())
            .frame(maxWidth: .infinity).padding(.vertical, 8)
    }
}

struct ViewerRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
    let start: Int
}

struct MessageBubble: View {
    let message: ChatMessage
    let model: AppModel
    let tapsDisabled: Bool
    let onPhoto: (ViewerRequest) -> Void
    let onButton: (ChatButton) -> Void
    let onDelete: () -> Void

    private var mine: Bool { message.role == .user }
    private var plain: String { mine ? message.text : TelegramHTML.plain(message.text) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if mine { Spacer(minLength: 56) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 6) {
                    if !message.photos.isEmpty { photos }
                    if !message.text.isEmpty {
                        Group {
                            if mine { Text(message.text) } else { Text(TelegramHTML.attributed(message.text)) }
                        }
                        .font(.body).foregroundStyle(mine ? Color.white : Color.primary).textSelection(.enabled)
                    }
                    meta
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(mine ? Theme.accent : Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contextMenu {
                    if !plain.isEmpty { Button { UIPasteboard.general.string = plain } label: { Label("Copy", systemImage: "doc.on.doc") } }
                    Button(role: .destructive, action: onDelete) { Label("Delete from this phone", systemImage: "trash") }
                }
                if !message.buttons.isEmpty { buttonRows }
            }
            if !mine { Spacer(minLength: 40) }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    private var meta: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            if message.edited { Text("edited") }
            Text(ChatFormat.time(message.date))
            if mine { ticks }
        }
        .font(.caption2).foregroundStyle(mine ? Color.white.opacity(0.75) : Color.secondary)
    }

    @ViewBuilder private var ticks: some View {
        switch message.delivery {
        case .sending: Image(systemName: "clock").accessibilityLabel("Sending")
        case .sent: Image(systemName: "checkmark").accessibilityLabel("Sent")
        case .answered:
            HStack(spacing: -5) { Image(systemName: "checkmark"); Image(systemName: "checkmark") }.accessibilityLabel("Read")
        }
    }

    @ViewBuilder private var photos: some View {
        let urls = message.photos.map { model.mediaURL($0) }
        let thumbs = message.photos.map { model.mediaURL($0, thumbnail: true) }
        let cols = message.photos.count == 1 ? 1 : 2
        let side: CGFloat = cols == 1 ? 230 : 112
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: 4), count: cols), spacing: 4) {
            ForEach(Array(thumbs.enumerated()), id: \.offset) { i, t in
                Group {
                    if let img = ChatImages.image(at: t) ?? ChatImages.image(at: urls[i]) {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(.quaternary).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                    }
                }
                .frame(width: side, height: cols == 1 ? 180 : side).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { onPhoto(ViewerRequest(urls: urls, start: i)) }
                .accessibilityLabel("Photo \(i + 1) of \(thumbs.count)").accessibilityAddTraits(.isButton)
            }
        }
    }

    /// Inline keyboard under a bot message, laid out in the rows the bot sent.
    private var buttonRows: some View {
        VStack(spacing: 4) {
            ForEach(Array(message.buttons.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 4) {
                    ForEach(row, id: \.self) { b in
                        Button { onButton(b) } label: {
                            Text(b.text).font(.subheadline.weight(.medium)).lineLimit(2).multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.plain).foregroundStyle(Theme.accent)
                        .background(Theme.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .disabled(tapsDisabled).opacity(tapsDisabled ? 0.5 : 1)
                    }
                }
            }
        }
        .frame(maxWidth: 300)
    }
}

struct TypingBubble: View {
    @State private var on = false
    var body: some View {
        HStack {
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle().fill(Color.secondary).frame(width: 7, height: 7)
                        .opacity(on ? 1 : 0.3).animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2), value: on)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Color(.secondarySystemGroupedBackground), in: Capsule())
            Spacer()
        }
        .onAppear { on = true }
        .accessibilityLabel("typing")
    }
}

// MARK: photo viewer
struct PhotoViewer: View {
    let request: ViewerRequest
    @State private var index: Int
    @Environment(\.dismiss) private var dismiss

    init(request: ViewerRequest) { self.request = request; _index = State(initialValue: request.start) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(request.urls.enumerated()), id: \.offset) { i, u in
                    ZoomableImage(url: u).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: request.urls.count > 1 ? .automatic : .never)).ignoresSafeArea()
            HStack(spacing: 14) {
                ShareLink(item: request.urls[index]) { Image(systemName: "square.and.arrow.up") }
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Close")
            }
            .font(.title2).foregroundStyle(.white).padding()
        }
    }
}

struct ZoomableImage: View {
    let url: URL
    @State private var scale: CGFloat = 1
    @State private var base: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            if let img = ChatImages.image(at: url) {
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    Image(uiImage: img).resizable().scaledToFit()
                        .frame(width: geo.size.width * scale, height: geo.size.height * scale)
                }
                .scrollBounceBehavior(.basedOnSize)
                .gesture(MagnifyGesture().onChanged { scale = min(max(base * $0.magnification, 1), 5) }.onEnded { _ in base = scale })
                .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2.5; base = scale } }
            } else {
                Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: camera
struct CameraPicker: UIViewControllerRepresentable {
    static var available: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }
    let onImage: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera; p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage, let d = img.jpegData(compressionQuality: 0.95) { parent.onImage(d) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
