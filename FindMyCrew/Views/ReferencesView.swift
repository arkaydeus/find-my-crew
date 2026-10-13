import SwiftUI

/// Steps ① and ②: add sample photos and mark which detected faces to search for.
struct ReferencesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.referencePhotos.isEmpty {
                Placeholder(
                    title: "Who are you looking for?",
                    systemImage: "person.2.crop.square.stack",
                    message: "Drop photos of the people you want to find, or click Add Photos.\nUse 3–10 varied photos per person for best results.",
                    actionTitle: "Add Photos…",
                    action: { model.addReferencePhotos(Panels.chooseImages()) }
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(model.referencePhotos) { photo in
                            ReferencePhotoRow(photo: photo)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .onFileDrop { model.addReferencePhotos($0) }
        .toolbar {
            ToolbarItemGroup {
                Button("Accept All", systemImage: "checkmark.circle") { model.setAllAccepted(true) }
                    .disabled(model.referencePhotos.isEmpty)
                Button("Reject All", systemImage: "xmark.circle") { model.setAllAccepted(false) }
                    .disabled(model.referencePhotos.isEmpty)
                Button("Add Photos…", systemImage: "plus") { model.addReferencePhotos(Panels.chooseImages()) }
                    .disabled(model.embedder == nil)
            }
        }
    }
}

private struct ReferencePhotoRow: View {
    @Environment(AppModel.self) private var model
    let photo: ReferencePhoto

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "photo").foregroundStyle(.secondary)
                Text(photo.url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                status
                Spacer()
                Button("Remove", systemImage: "trash", role: .destructive) { model.removeReferencePhoto(photo.id) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .help("Remove this photo")
            }
            if !photo.faces.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(photo.faces) { FaceTile(face: $0) }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var status: some View {
        switch photo.state {
        case .loading:
            ProgressView().controlSize(.small)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption)
        case .done:
            Text(photo.faces.isEmpty ? "No faces found"
                 : photo.faces.count == 1 ? "1 face" : "\(photo.faces.count) faces — choose who to find")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct FaceTile: View {
    @Environment(AppModel.self) private var model
    let face: ReferenceFace

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let crop = face.crop {
                        Image(decorative: crop, scale: 1).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(face.accepted ? Color.green : Color.secondary.opacity(0.3), lineWidth: face.accepted ? 3 : 1))
                .opacity(face.accepted ? 1 : 0.6)

                if let warning = face.face.qualityWarning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow, .black)
                        .padding(5)
                        .help("\(warning) — this face may give less reliable matches.")
                        .accessibilityLabel(warning)
                }
            }
            Picker("Search for this face", selection: Binding(
                get: { face.accepted },
                set: { model.setAccepted($0, faceID: face.id) }
            )) {
                Text("Yes").tag(true)
                Text("No").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 120)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Face, \(face.accepted ? "selected" : "not selected")")
    }
}
