import CoreML
import Foundation
import UniformTypeIdentifiers

private final class BundleLocator {}

/// Resolves the active face-recognition model: the bundled SFace model or a user-imported one.
enum ModelStore {
    static let builtInName = "SFace"
    static let builtInDisplayName = "Built-in (SFace, Apache-2.0)"

    /// The app's bundled model; when Core is compiled into another bundle (the tests), that bundle's copy.
    static var builtInURL: URL? {
        Bundle.main.url(forResource: builtInName, withExtension: "mlmodelc")
            ?? Bundle(for: BundleLocator.self).url(forResource: builtInName, withExtension: "mlmodelc")
    }

    static var customDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "FindMyCrew/Models", directoryHint: .isDirectory)
    }

    static func customURL(named name: String) -> URL {
        customDirectory.appending(path: name, directoryHint: .isDirectory)
    }

    /// File types the model import panel accepts. `.mlpackage` and `.mlmodelc` are directories (packages): without
    /// `conformingTo: .package` the lookup yields a data type that no package matches, and they show up greyed out.
    static let importableTypes: [UTType] = [
        UTType(filenameExtension: "mlpackage", conformingTo: .package),
        UTType(filenameExtension: "mlmodel"),
        UTType(filenameExtension: "mlmodelc", conformingTo: .package),
    ].compactMap { $0 }

    static func installedCustomModels() -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: customDirectory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "mlmodelc" }.map(\.lastPathComponent).sorted()
    }

    /// Loads the model for a stored setting (`""` = built-in, otherwise a custom `.mlmodelc` name).
    static func loadEmbedder(customModelName: String) async throws -> FaceEmbedder {
        if !customModelName.isEmpty {
            let url = customURL(named: customModelName)
            return try FaceEmbedder(compiledModelURL: url, displayName: (customModelName as NSString).deletingPathExtension)
        }
        guard let url = builtInURL else { throw CocoaError(.fileNoSuchFile) }
        return try FaceEmbedder(compiledModelURL: url, displayName: builtInDisplayName)
    }

    /// Compiles and validates a user-supplied model against the I/O contract, then stores it.
    /// Returns the stored `.mlmodelc` name. Throws `EmbedderError` describing any contract violation.
    static func importModel(from source: URL) async throws -> (name: String, embedder: FaceEmbedder) {
        let isCompiled = source.pathExtension == "mlmodelc"
        let compiled: URL
        do {
            compiled = isCompiled ? source : try await MLModel.compileModel(at: source)
        } catch {
            throw EmbedderError.notACoreMLModel(error.localizedDescription)
        }
        defer { if !isCompiled { try? FileManager.default.removeItem(at: compiled) } }
        let name = source.deletingPathExtension().lastPathComponent + ".mlmodelc"
        // Validate before installing.
        do {
            try FaceEmbedder(compiledModelURL: compiled, displayName: name).selfTest()
        } catch let error as EmbedderError {
            throw error
        } catch {
            throw EmbedderError.notACoreMLModel(error.localizedDescription)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: customDirectory, withIntermediateDirectories: true)
        let destination = customURL(named: name)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: compiled, to: destination)
        let embedder = try FaceEmbedder(compiledModelURL: destination, displayName: (name as NSString).deletingPathExtension)
        return (name, embedder)
    }

    static func removeCustomModel(named name: String) throws {
        try FileManager.default.removeItem(at: customURL(named: name))
    }
}
