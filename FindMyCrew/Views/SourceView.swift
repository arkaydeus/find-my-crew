import SwiftUI

/// Step ③: choose the folder to search.
struct SourceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let root = model.sourceRoot {
                Form {
                    Section("Folder to search") {
                        LabeledContent("Location") {
                            HStack {
                                Text(root.path(percentEncoded: false)).lineLimit(1).truncationMode(.head)
                                    .textSelection(.enabled)
                                Button("Change…", action: choose)
                            }
                        }
                        LabeledContent("Photos found") { counts }
                    }
                    if let skipped = model.enumeration?.skippedPackages, !skipped.isEmpty {
                        Section("Skipped") {
                            Text("These are app packages (e.g. a Photos library) and are not searched. Export the photos from the app first if you need them.")
                                .font(.callout).foregroundStyle(.secondary)
                            ForEach(skipped, id: \.self) { Text($0).font(.callout.monospaced()) }
                        }
                    }
                    Section {
                        Label("Every sub-folder is included. Your original photos are never modified.", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            } else {
                Placeholder(
                    title: "Where are the photos?",
                    systemImage: "folder.badge.questionmark",
                    message: "Choose the folder to search. All sub-folders are included.",
                    actionTitle: "Choose Folder…",
                    action: choose
                )
            }
        }
        .onFileDrop(kind: .folders) { model.receiveDrop($0, kind: .folders) }
    }

    @ViewBuilder private var counts: some View {
        if let count = model.enumeratingCount {
            HStack { ProgressView().controlSize(.small); Text("Counting… \(count)") }
        } else if let error = model.enumerationError {
            Text(error).foregroundStyle(.red)
        } else if let e = model.enumeration {
            let bytes = e.items.reduce(Int64(0)) { $0 + $1.fileSize }
            Text("\(e.items.count) images in \(e.folderCount + 1) folders (\(bytes.byteString))")
                .foregroundStyle(e.items.isEmpty ? .red : .primary)
        }
    }

    private func choose() {
        Task {
            if let url = await Panels.chooseFolder(prompt: "Choose", message: "Choose the folder that contains your photos.") {
                model.chooseSource(url)
            }
        }
    }
}
