import Foundation

/// User preferences persisted in UserDefaults.
struct AppSettings: Equatable {
    private static var defaults: UserDefaults { .standard }

    /// Empty = built-in model; otherwise the name of an imported `.mlmodelc`.
    var customModelName: String = defaults.string(forKey: "customModelName") ?? "" {
        didSet { Self.defaults.set(customModelName, forKey: "customModelName") }
    }

    var workingResolution: Int = (defaults.object(forKey: "workingResolution") as? Int) ?? 2048 {
        didSet { Self.defaults.set(workingResolution, forKey: "workingResolution") }
    }

    var flipAugmentation: Bool = (defaults.object(forKey: "flipAugmentation") as? Bool) ?? true {
        didSet { Self.defaults.set(flipAugmentation, forKey: "flipAugmentation") }
    }

    static let resolutionChoices = [1600, 2048, 3072]

    var pipelineOptions: PipelineOptions {
        PipelineOptions(workingResolution: workingResolution, flipAugmentation: flipAugmentation)
    }
}
