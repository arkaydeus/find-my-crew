import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var installed: [String] = ModelStore.installedCustomModels()
    @State private var importError: String?
    @State private var importing = false

    var body: some View {
        Form {
            Section {
                Picker("Recognition model", selection: Binding(
                    get: { model.settings.customModelName },
                    set: { apply { $0.customModelName = $1 }($0) }
                )) {
                    Text(ModelStore.builtInDisplayName).tag("")
                    ForEach(installed, id: \.self) { Text(($0 as NSString).deletingPathExtension).tag($0) }
                }
                HStack {
                    Button("Import Core ML Model…", action: importModel).disabled(importing)
                    if importing { ProgressView().controlSize(.small) }
                    if !model.settings.customModelName.isEmpty {
                        Button("Remove", role: .destructive) {
                            let name = model.settings.customModelName
                            apply { $0.customModelName = $1 }("")
                            try? ModelStore.removeCustomModel(named: name)
                            installed = ModelStore.installedCustomModels()
                        }
                    }
                }
                if let importError { Text(importError).foregroundStyle(.red).font(.caption) }
                if let embedder = model.embedder {
                    LabeledContent("Active", value: "\(embedder.displayName) · \(embedder.dimension)-D · threshold \(String(format: "%.2f", embedder.defaultThreshold))")
                        .font(.caption)
                }
            } header: {
                Text("Face recognition")
            } footer: {
                Text("Custom models must take a square RGB face image and output an embedding (see scripts/models/README.md). You are responsible for complying with the model’s licence — many research models (e.g. InsightFace ArcFace) are for non-commercial use only.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Performance") {
                Picker("Detection resolution", selection: Binding(
                    get: { model.settings.workingResolution },
                    set: { apply { $0.workingResolution = $1 }($0) }
                )) {
                    ForEach(AppSettings.resolutionChoices, id: \.self) { Text("\($0) px").tag($0) }
                }
                Toggle("Mirror augmentation (more accurate, slower)", isOn: Binding(
                    get: { model.settings.flipAugmentation },
                    set: { apply { $0.flipAugmentation = $1 }($0) }
                ))
                Text("Changing these settings clears scan results.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Returns a setter that updates a setting and rebuilds the pipeline if it changed.
    private func apply<T: Equatable>(_ update: @escaping (inout AppSettings, T) -> Void) -> (T) -> Void {
        { value in
            var s = model.settings
            update(&s, value)
            guard s != model.settings else { return }
            model.settings = s
            Task { await model.pipelineChanged() }
        }
    }

    private func importModel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mlpackage"), UTType(filenameExtension: "mlmodel"),
                                     UTType(filenameExtension: "mlmodelc")].compactMap { $0 }
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = true
        importError = nil
        Task {
            do {
                let (name, _) = try await ModelStore.importModel(from: url)
                installed = ModelStore.installedCustomModels()
                apply { $0.customModelName = $1 }(name)
            } catch {
                importError = error.localizedDescription
            }
            importing = false
        }
    }
}
