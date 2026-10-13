import SwiftUI

/// Step ④: scan progress.
struct ScanView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let total = max(model.totalCount, 1)
        let processed = model.processedCount
        let recent = model.results.suffix(400).filter { $0.bestScore >= model.threshold }.suffix(12)

        VStack(spacing: 24) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 54))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, isActive: model.scanStatus == .running)

            VStack(spacing: 8) {
                ProgressView(value: Double(processed), total: Double(total))
                    .frame(maxWidth: 520)
                Text("\(processed) of \(model.totalCount) photos")
                    .font(.title3.monospacedDigit())
                Text(model.lastScannedPath).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 520)
            }

            Grid(horizontalSpacing: 28, verticalSpacing: 6) {
                GridRow {
                    stat("\(model.results.filter { $0.bestScore >= model.threshold }.count)", "matches")
                    stat("\(model.facesFound)", "faces seen")
                    stat(String(format: "%.1f/s", model.photosPerSecond), "speed")
                    stat(eta, "remaining")
                    stat("\(model.failedCount)", "unreadable")
                }
            }

            if !recent.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(recent)) { r in
                        ThumbnailView(url: r.item.url, highlight: r.bestFace?.box)
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .frame(height: 76)
            }

            HStack {
                switch model.scanStatus {
                case .running, .paused:
                    Button(model.scanStatus == .paused ? "Resume" : "Pause",
                           systemImage: model.scanStatus == .paused ? "play.fill" : "pause.fill") { model.togglePause() }
                    Button("Stop", systemImage: "stop.fill", role: .destructive) { model.cancelScan() }
                case .cancelled:
                    Text("Scan stopped. You can review the photos scanned so far.").foregroundStyle(.secondary)
                    Button("Review Results") { model.step = .review }.disabled(model.results.isEmpty)
                    Button("Restart Scan") { model.startScan() }
                case .finished:
                    Button("Review Results") { model.step = .review }.buttonStyle(.borderedProminent)
                case .idle:
                    Button("Start Scan") { model.startScan() }.buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
            Spacer()
        }
        .padding(32)
    }

    private var icon: String {
        switch model.scanStatus {
        case .finished: "checkmark.circle"
        case .paused: "pause.circle"
        case .cancelled: "stop.circle"
        default: "viewfinder"
        }
    }

    private var eta: String {
        let rate = model.photosPerSecond
        guard rate > 0, model.scanStatus == .running else { return "—" }
        let seconds = Double(model.totalCount - model.processedCount) / rate
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack {
            Text(value).font(.title2.monospacedDigit().weight(.semibold))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
