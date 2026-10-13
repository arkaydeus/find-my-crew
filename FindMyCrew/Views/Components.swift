import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Thread-safe in-memory cache of small thumbnails for grids.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, CGImage>()

    init() { cache.countLimit = 600 }

    func thumbnail(for url: URL, maxPixel: Int = 360) async -> CGImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        let image = await Task.detached(priority: .utility) {
            try? ImageLoader.thumbnail(url, maxPixel: maxPixel)
        }.value
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}

/// Asynchronously loaded, aspect-fit thumbnail with optional face-box overlay.
struct ThumbnailView: View {
    let url: URL
    var highlight: CGRect?
    var highlightColor: Color = .green

    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .overlay {
                        if let highlight {
                            GeometryReader { geo in
                                Rectangle()
                                    .strokeBorder(highlightColor, lineWidth: 2)
                                    .frame(width: highlight.width * geo.size.width, height: highlight.height * geo.size.height)
                                    .offset(x: highlight.minX * geo.size.width, y: highlight.minY * geo.size.height)
                            }
                        }
                    }
            } else {
                Rectangle().fill(.quaternary)
                ProgressView().controlSize(.small)
            }
        }
        .task(id: url) { image = await ThumbnailCache.shared.thumbnail(for: url) }
    }
}

/// Drop target accepting file URLs.
struct FileDropModifier: ViewModifier {
    var onDrop: ([URL]) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                        .background(Color.accentColor.opacity(0.08))
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                onDrop(urls)
                return !urls.isEmpty
            } isTargeted: { targeted = $0 }
    }
}

extension View {
    func onFileDrop(_ action: @escaping ([URL]) -> Void) -> some View {
        modifier(FileDropModifier(onDrop: action))
    }
}

/// Open panels, shown as sheets on the active window. Unlike `runModal`, a sheet doesn't block the main thread
/// (progress keeps updating), and only one panel can be open at a time even if a button is triggered again
/// (e.g. through accessibility while a panel is up), which previously stacked modal sessions and wedged the app.
@MainActor
enum Panels {
    private static var isPresenting = false

    static func present(_ panel: NSOpenPanel) async -> [URL] {
        guard !isPresenting else { return [] }
        isPresenting = true
        defer { isPresenting = false }
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.attachedSheet == nil {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await panel.begin()
        }
        return response == .OK ? panel.urls : []
    }

    static func chooseImages() async -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Add Photos"
        panel.message = "Choose photos of the people you want to find."
        return await present(panel)
    }

    static func chooseFolder(prompt: String, message: String, canCreate: Bool = false) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = canCreate
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = message
        return await present(panel).first
    }
}

extension Int64 {
    var byteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

/// Large empty-state placeholder.
struct Placeholder: View {
    var title: String
    var systemImage: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
    }
}
