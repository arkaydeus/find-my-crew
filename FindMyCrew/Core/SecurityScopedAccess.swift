import Foundation

/// Holds a sandbox grant for as long as a photo/folder or one of its background jobs uses it.
/// Ordinary URLs may already be accessible and return false; only successful starts need stopping.
final class SecurityScopedAccess: @unchecked Sendable {
    let url: URL
    private let accessed: Bool
    private let stop: @Sendable (URL) -> Void

    init(_ url: URL,
         start: @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stop: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        self.url = url
        self.stop = stop
        accessed = start(url)
    }

    deinit { if accessed { stop(url) } }
}
