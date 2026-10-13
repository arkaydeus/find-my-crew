import SwiftUI

/// Step ⑥: copy the selected photos, preserving folder structure.
struct ExportView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let plan = model.plannedOperations()

        Form {
            Section("Destination") {
                LabeledContent("Copy to") {
                    HStack {
                        if let destination = model.destination {
                            Text(destination.path(percentEncoded: false)).lineLimit(1).truncationMode(.head)
                        } else {
                            Text("Not chosen").foregroundStyle(.secondary)
                        }
                        Button("Choose…") {
                            Task {
                                model.destination = await Panels.chooseFolder(
                                    prompt: "Copy Here", message: "Choose where to copy the matching photos.", canCreate: true
                                ) ?? model.destination
                            }
                        }
                        .disabled(model.isExporting)
                    }
                }
                Toggle("Also copy sidecar files (RAW+JPEG pairs, .xmp, .aae)", isOn: $model.includeSidecars)
                    .disabled(model.isExporting)
            }

            Section("Summary") {
                switch plan {
                case nil:
                    Text("Choose a destination folder to see what will be copied.").foregroundStyle(.secondary)
                case .failure(let error)?:
                    Label(error.localizedDescription, systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
                case .success(let ops)?:
                    let bytes = ops.reduce(Int64(0)) { $0 + $1.bytes }
                    let folders = Set(ops.map { $0.to.deletingLastPathComponent() }).count
                    let sidecars = ops.filter(\.isSidecar).count
                    LabeledContent("Photos", value: "\(ops.count - sidecars)")
                    if sidecars > 0 { LabeledContent("Sidecar files", value: "\(sidecars)") }
                    LabeledContent("Folders", value: "\(folders)")
                    LabeledContent("Total size", value: bytes.byteString)
                    Text("The original sub-folder structure is recreated. Existing files are never overwritten.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                if let progress = model.exportProgress, model.isExporting {
                    HStack {
                        ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        Text("\(progress.done)/\(progress.total)").monospacedDigit()
                        Button("Cancel") { model.cancelExport() }
                    }
                } else {
                    HStack {
                        Spacer()
                        Button {
                            model.startExport()
                        } label: {
                            Label("Copy Photos", systemImage: "square.and.arrow.down.on.square")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled({ if case .success(let ops)? = plan { ops.isEmpty } else { true } }())
                    }
                }
            }

            if let summary = model.exportSummary {
                Section(summary.completionTitle) {
                    if summary.cancelled {
                        Text("Copy stopped before all files were processed. You can copy again to continue.")
                    }
                    if !summary.cancelled && summary.copied == 0 && summary.failures.isEmpty && summary.skippedIdentical > 0 {
                        Label("Nothing new to copy — all \(summary.skippedIdentical) files are already at the destination.",
                              systemImage: summary.cancelled ? "stop.circle" : "checkmark.circle.fill")
                            .foregroundStyle(summary.cancelled ? .orange : .green)
                    } else {
                        Label("\(summary.copied) files copied (\(summary.bytesCopied.byteString))", systemImage: summary.cancelled ? "stop.circle" : "checkmark.circle.fill")
                            .foregroundStyle(summary.cancelled ? .orange : .green)
                    }
                    if summary.skippedIdentical > 0 && (summary.copied > 0 || summary.cancelled) {
                        Text("\(summary.skippedIdentical) already existed at the destination and were skipped.")
                    }
                    if summary.renamed > 0 {
                        Text("\(summary.renamed) were renamed to avoid overwriting different files with the same name.")
                    }
                    if !summary.failures.isEmpty {
                        DisclosureGroup("\(summary.failures.count) failed") {
                            ForEach(summary.failures, id: \.path) { f in
                                VStack(alignment: .leading) {
                                    Text(f.path).font(.caption.monospaced())
                                    Text(f.message).font(.caption).foregroundStyle(.red)
                                }
                            }
                        }
                    }
                    if let destination = model.destination {
                        Button("Show in Finder") { NSWorkspace.shared.open(destination) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
