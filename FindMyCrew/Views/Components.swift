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

/// Drop target accepting file URLs, plus images from apps such as Photos that drag image data or file
/// promises instead of URLs (those are copied to a temporary folder first).
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
            .onDrop(of: [.fileURL, .image], isTargeted: $targeted) { providers in
                Task {
                    let urls = await DroppedItems.urls(from: providers)
                    if !urls.isEmpty { onDrop(urls) }
                }
                return true
            }
    }
}

@MainActor
enum DroppedItems {
    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let url = await fileURL(from: provider) {
                urls.append(url)
            } else if let url = await imageCopy(from: provider) {
                urls.append(url)
            }
        }
        return urls
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { @Sendable url, _ in continuation.resume(returning: url) }
        }
    }

    /// Copies the dropped image out, since the provided file is deleted once the handler returns.
    private static func imageCopy(from provider: NSItemProvider) async -> URL? {
        guard let type = provider.registeredContentTypes.first(where: { $0.conforms(to: .image) }) else { return nil }
        let suggestedName = provider.suggestedName
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type) { @Sendable file, _, _ in
                continuation.resume(returning: file.flatMap { try? copy($0, type: type, name: suggestedName) })
            }
        }
    }

    nonisolated private static func copy(_ file: URL, type: UTType, name: String?) throws -> URL {
        let dir = URL.temporaryDirectory.appending(path: "Dropped Photos/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = name ?? file.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension.isEmpty ? type.preferredFilenameExtension ?? "" : file.pathExtension
        let destination = dir.appending(path: base).appendingPathExtension(ext)
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
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
            // ContentUnavailableView caps the description width; keep each line whole.
            Text(message).fixedSize(horizontal: true, vertical: false)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
    }
}
