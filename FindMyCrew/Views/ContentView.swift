import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: Binding(get: { model.step }, set: { if let s = $0, model.canEnter(s) { model.step = s } })) {
                ForEach(Step.allCases) { step in
                    Label(step.title, systemImage: step.systemImage)
                        .badge(badge(for: step))
                        .foregroundStyle(model.canEnter(step) ? .primary : .tertiary)
                        .tag(step)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .bottom) { modelStatus.padding(10) }
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch model.step {
                    case .references: ReferencesView()
                    case .source: SourceView()
                    case .scan: ScanView()
                    case .review: ReviewView()
                    case .export: ExportView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                navigationBar
            }
            .navigationTitle(model.step.title)
        }
        .alert("Some items couldn’t be added", isPresented: Binding(
            get: { !model.dropFailures.isEmpty },
            set: { if !$0 { model.dropFailures.removeAll() } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(model.dropFailureMessage ?? "")
        }
    }

    private func badge(for step: Step) -> Text? {
        switch step {
        case .references: model.acceptedFaces.isEmpty ? nil : Text("\(model.acceptedFaces.count)")
        case .source: model.enumeration.map { Text("\($0.items.count)") }
        case .review: model.results.isEmpty ? nil : Text("\(model.selectedResults.count)")
        default: nil
        }
    }

    @ViewBuilder private var modelStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.modelError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
            if let embedder = model.embedder {
                Label(embedder.displayName, systemImage: "cpu")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else if model.modelError == nil {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var navigationBar: some View {
        HStack {
            if let previous = model.previousStep {
                Button {
                    model.step = previous
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(model.scanStatus == .running || model.scanStatus == .paused)
            }
            Spacer()
            hint.font(.callout).foregroundStyle(.secondary)
            Spacer()
            primaryAction
        }
        .padding(.vertical, 12)
        // Matches the reference cards' inset so Back and Next line up with their edges.
        .padding(.horizontal, 20)
        .background(.bar)
    }

    @ViewBuilder private var hint: some View {
        switch model.step {
        case .references:
            if model.acceptedFaces.isEmpty { Text("Add photos and mark at least one face “Yes”.") }
            else { Text("\(model.acceptedFaces.count) face(s) will be searched for.") }
        case .source:
            if model.referencesAreStale { Text("Faces changed since the last scan. Scan again to update results.") }
        default: EmptyView()
        }
    }

    @ViewBuilder private var primaryAction: some View {
        switch model.step {
        case .source:
            Button {
                model.startScan()
            } label: {
                Label(model.results.isEmpty ? "Start Scan" : "Scan Again", systemImage: "viewfinder")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canEnter(.scan) || model.pipeline == nil)
        case .export:
            EmptyView()
        default:
            if let next = model.nextStep {
                Button {
                    model.step = next
                } label: {
                    Label("Next", systemImage: "chevron.right").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canEnter(next))
            }
        }
    }
}
