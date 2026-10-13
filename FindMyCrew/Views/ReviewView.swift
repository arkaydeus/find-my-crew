import QuickLook
import SwiftUI

/// Step ⑤: review matches, tune the threshold, exclude false positives.
struct ReviewView: View {
    @Environment(AppModel.self) private var model
    @State private var previewURL: URL?
    @State private var focused: URL?
    @State private var showNearMisses = true

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 12)]

    var body: some View {
        @Bindable var model = model
        let matches = model.matches
        let nearMisses = model.nearMisses

        VStack(spacing: 0) {
            controls(matches: matches)
            Divider()
            if matches.isEmpty && nearMisses.isEmpty {
                Placeholder(title: "No matches", systemImage: "person.fill.questionmark",
                            message: "Try lowering the match threshold, or add more reference photos.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(matches) { tile($0) }
                        }
                        if !nearMisses.isEmpty {
                            DisclosureGroup(isExpanded: $showNearMisses) {
                                LazyVGrid(columns: columns, spacing: 12) {
                                    ForEach(nearMisses) { tile($0) }
                                }
                                .padding(.top, 8)
                            } label: {
                                Text("Near misses (\(nearMisses.count)) — just below the threshold. Tick any that are a match.")
                                    .font(.headline)
                            }
                        }
                    }
                    .padding(16)
                }
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.space) {
                    guard let focused else { return .ignored }
                    previewURL = focused
                    return .handled
                }
            }
        }
        .quickLookPreview($previewURL, in: (matches + nearMisses).map(\.item.url))
    }

    private func controls(matches: [PhotoResult]) -> some View {
        @Bindable var model = model
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.selectedResults.count) photos selected")
                    .font(.headline)
                Text("\(matches.count) matches · \(model.excluded.count) excluded · \(model.results.count) scanned")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("Looser").font(.caption).foregroundStyle(.secondary)
            Slider(value: $model.threshold, in: model.thresholdRange)
                .frame(width: 260)
                .help("Match threshold (cosine similarity). Higher = stricter, fewer false matches.")
                .accessibilityLabel("Match threshold")
            Text("Stricter").font(.caption).foregroundStyle(.secondary)
            Text(String(format: "%.2f", model.threshold)).font(.body.monospacedDigit()).frame(width: 38)
            Button("Reset") { model.threshold = model.embedder?.defaultThreshold ?? model.threshold }
                .disabled(model.threshold == model.embedder?.defaultThreshold)
        }
        .padding(12)
    }

    private func tile(_ result: PhotoResult) -> some View {
        let included = model.isIncluded(result)
        let isFocused = focused == result.id
        return VStack(alignment: .leading, spacing: 6) {
            ThumbnailView(url: result.item.url, highlight: result.bestFace?.box,
                          highlightColor: included ? .green : .orange)
                .frame(height: 160)
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .opacity(included ? 1 : 0.45)
                .overlay(alignment: .topLeading) {
                    Toggle("Include", isOn: Binding(
                        get: { included },
                        set: { model.setIncluded($0, for: result) }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                    .padding(6)
                }
                .overlay(alignment: .topTrailing) {
                    Text(String(format: "%.0f%%", max(0, result.bestScore) * 100))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                        .padding(6)
                        .help("Similarity to the closest reference face")
                }
            Text(result.item.relativePath)
                .font(.caption).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.secondary)
                .help(result.item.relativePath)
        }
        .padding(6)
        .background(isFocused ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { previewURL = result.item.url }
        .onTapGesture { focused = result.id }
        .contextMenu {
            Button(included ? "Exclude" : "Include") { model.setIncluded(!included, for: result) }
            Button("Quick Look") { previewURL = result.item.url }
            Button("Reveal in Finder") { model.reveal(result.item.url) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(result.item.relativePath), \(included ? "included" : "excluded")")
    }
}
