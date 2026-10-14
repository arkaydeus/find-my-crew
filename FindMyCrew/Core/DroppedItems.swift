import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers

/// Shared ownership of a drop's sandbox grant or app-owned copy. Background readers retain the
/// same object, so removing a reference never deletes a file while it is still being processed.
final class DroppedFile: @unchecked Sendable {
    let url: URL
    let access: SecurityScopedAccess
    let contentID: String?
    private let ownedCopy: DroppedCopyLease?

    init(url: URL, access: SecurityScopedAccess? = nil, contentID: String? = nil, ownedCopy: DroppedCopyLease? = nil) {
        self.url = url
        self.access = access ?? SecurityScopedAccess(url)
        self.contentID = contentID
        self.ownedCopy = ownedCopy
    }
}

struct DropFailure: Sendable {
    let name: String
    let reason: String
}

struct DropResult: Sendable {
    var files: [DroppedFile] = []
    var failures: [DropFailure] = []

    var failureMessage: String? {
        guard !failures.isEmpty else { return nil }
        return failures.map { "\($0.name): \($0.reason)" }.joined(separator: "\n")
            + "\nTry exporting these photos to Finder, then drop them again."
    }
}

enum DropKind: Sendable {
    case images, folders
    var acceptedTypes: [UTType] { self == .images ? [.fileURL, .image] : [.fileURL] }
}

/// Kept outside Views so real NSItemProvider negotiation is covered by the hostless tests.
@MainActor
enum DroppedItems {
    static func resolve(_ providers: [NSItemProvider], kind: DropKind = .images,
                        copyRoot: URL = defaultCopyRoot) async -> DropResult {
        var result = DropResult()
        for provider in providers {
            let name = provider.suggestedName ?? "Dropped item"
            var errors: [String] = []
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                do {
                    let file = try await fileURL(from: provider, kind: kind)
                    result.files.append(file)
                    continue
                } catch { errors.append(error.localizedDescription) }
            }
            if kind == .images {
                let types = provider.registeredContentTypes.filter { supportedExtension(for: $0) != nil }
                var loaded: DroppedFile?
                for type in types {
                    do {
                        loaded = try await imageCopy(from: provider, type: type, root: copyRoot)
                        break
                    } catch { errors.append("\(type.localizedDescription ?? type.identifier): \(error.localizedDescription)") }
                }
                if let loaded {
                    result.files.append(loaded)
                    continue
                }
            }
            result.failures.append(DropFailure(name: name, reason: errors.isEmpty
                ? (kind == .folders ? "Drop a folder from Finder." : "No supported photo representation was provided.")
                : errors.joined(separator: "; ")))
        }
        return result
    }

    private static func fileURL(from provider: NSItemProvider, kind: DropKind) async throws -> DroppedFile {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { @Sendable url, error in
                do {
                    if let error { throw error }
                    guard let url, url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
                    // Acquire the grant before checking access, and keep it through the consumer handoff.
                    let access = SecurityScopedAccess(url)
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                    let directory = values.isDirectory == true
                    guard kind == .folders ? directory : (!directory && ImageLoader.isSupported(url)) else {
                        throw DropError.wrongKind(kind)
                    }
                    if directory {
                        _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                    } else {
                        let handle = try FileHandle(forReadingFrom: url)
                        try handle.close()
                    }
                    // Directory status comes from the filesystem, not a trailing slash supplied by the provider.
                    let normalized = URL(filePath: url.path, directoryHint: directory ? .isDirectory : .notDirectory)
                    continuation.resume(returning: DroppedFile(url: normalized, access: access))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func imageCopy(from provider: NSItemProvider, type: UTType, root: URL) async throws -> DroppedFile {
        let name = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { @Sendable file, error in
                do {
                    if let error { throw error }
                    guard let file else { throw CocoaError(.fileReadUnknown) }
                    // Apple's temporary URL is valid only inside this callback. Copy before resuming.
                    continuation.resume(returning: try copy(file, type: type, name: name, root: root))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    nonisolated static var defaultCopyRoot: URL {
        URL.temporaryDirectory.appending(path: "Dropped Photos", directoryHint: .isDirectory)
    }

    /// Recover copies abandoned by a crashed process. Per-copy advisory locks protect other app
    /// instances and readers; the age guard avoids racing a directory whose lock is being created.
    nonisolated static func purgeStaleCopies(root: URL = defaultCopyRoot, now: Date = Date()) {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)) else { return }
        for dir in dirs where UUID(uuidString: dir.lastPathComponent) != nil {
            guard let values = try? dir.resourceValues(forKeys: keys), values.isDirectory == true,
                  values.isSymbolicLink != true, let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) > 60 else { continue }
            let fd = open(dir.appending(component: ".lease").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { continue }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { try? fm.removeItem(at: dir) }
            close(fd)
        }
    }

    nonisolated static func supportedExtension(for type: UTType) -> String? {
        guard type.conforms(to: .image), let ext = type.preferredFilenameExtension,
              ImageLoader.isSupported(URL(filePath: "photo.\(ext)")) else { return nil }
        return ext
    }

    nonisolated static func copy(_ file: URL, type: UTType, name: String?,
                                root: URL = defaultCopyRoot) throws -> DroppedFile {
        guard let preferred = supportedExtension(for: type) else { throw DropError.wrongKind(.images) }
        let dir = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        do {
            let ownership = try DroppedCopyLease(directory: dir)
            // Treat both separator styles as untrusted. A name is always a single, bounded component.
            let component = (name ?? file.lastPathComponent).replacingOccurrences(of: "\\", with: "/")
                .components(separatedBy: "/").last ?? "Photo"
            let stem = (component as NSString).deletingPathExtension
                .components(separatedBy: .controlCharacters).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var base = stem.isEmpty || stem == "." || stem == ".." ? "Photo" : stem
            while base.utf8.count > 180 { base.removeLast() }
            let sourceExt = file.pathExtension.lowercased()
            let compatible = UTType(filenameExtension: sourceExt).map { $0.conforms(to: type) } == true
                && ImageLoader.isSupported(file)
            let destination = dir.appending(component: base).appendingPathExtension(compatible ? sourceExt : preferred)
                .standardizedFileURL
            guard destination.deletingLastPathComponent() == dir.standardizedFileURL else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            try FileManager.default.copyItem(at: file, to: destination)
            // Stream the digest rather than holding a full-resolution photo in memory.
            let handle = try FileHandle(forReadingFrom: destination)
            defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
            let identity = hash.finalize().map { String(format: "%02x", $0) }.joined()
            return DroppedFile(url: destination, contentID: identity, ownedCopy: ownership)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }
}

private enum DropError: LocalizedError {
    case wrongKind(DropKind)
    var errorDescription: String? {
        switch self {
        case .wrongKind(.images): "This item is not a supported photo."
        case .wrongKind(.folders): "Drop a folder from Finder."
        }
    }
}

/// The lock is held until the last consumer releases the copy, including detached readers.
final class DroppedCopyLease: @unchecked Sendable {
    let directory: URL
    private let descriptor: Int32

    init(directory: URL) throws {
        self.directory = directory
        let fd = open(directory.appending(component: ".lease").path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw CocoaError(.fileWriteUnknown)
        }
        descriptor = fd
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
        close(descriptor)
    }
}
