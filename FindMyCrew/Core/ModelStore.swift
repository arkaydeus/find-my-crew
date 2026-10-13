import CoreML
import Foundation

/// Resolves the active face-recognition model: the bundled SFace model or a user-imported one.
enum ModelStore {
    static let builtInName = "SFace"
    static let builtInDisplayName = "Built-in (SFace, Apache-2.0)"

    static var builtInURL: URL? {
        Bundle.main.url(forResource: builtInName, withExtension: "mlmodelc")
    }

    static var customDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "FindMyCrew/Models", directoryHint: .isDirectory)
    }

    static func customURL(named name: String) -> URL {
        customDirectory.appending(path: name, directoryHint: .isDirectory)
    }

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

    /// Compiles and validates a user-supplied model, then stores it. Returns the stored `.mlmodelc` name.
    static func importModel(from source: URL) async throws -> (name: String, embedder: FaceEmbedder) {
        let compiled = source.pathExtension == "mlmodelc" ? source : try await MLModel.compileModel(at: source)
        let name = source.deletingPathExtension().lastPathComponent + ".mlmodelc"
        // Validate before installing.
        _ = try FaceEmbedder(compiledModelURL: compiled, displayName: name)

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
