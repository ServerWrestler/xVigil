import SwiftUI
import UniformTypeIdentifiers
import xVigilCore
import xVigilScan

struct ScanPaneView: View {
    let model: DashboardModel
    @State private var showingPathPicker = false

    var body: some View {
        @Bindable var scanner = model.scanner
        Form {
            engineSection
            pathsSection
            scheduleSection(scanner: $scanner)
            resultsSection
        }
        .formStyle(.grouped)
        .onAppear {
            if model.scanner.engineAvailability == nil { model.scanner.checkEngine() }
        }
        .fileImporter(
            isPresented: $showingPathPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            for url in (try? result.get()) ?? [] {
                model.scanner.addPath(url)
            }
        }
    }

    private var scanner: ScanController { model.scanner }

    // MARK: Engine status

    @ViewBuilder
    private var engineSection: some View {
        Section("Engine") {
            if let availability = scanner.engineAvailability {
                if availability.installed {
                    LabeledContent("ClamAV") {
                        Label(
                            availability.daemonRunning ? "Ready (daemon)" : "Ready (slow mode)",
                            systemImage: "checkmark.circle.fill")
                            .foregroundStyle(availability.daemonRunning ? .green : .orange)
                    }
                    signatureAgeRow(availability)
                } else {
                    Label {
                        Text("ClamAV is not installed. Install with `brew install clamav`, then run `freshclam` to download signatures.")
                    } icon: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    }
                }
                Text(availability.detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Button("Re-check") { scanner.checkEngine() }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking for ClamAV…").foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func signatureAgeRow(_ availability: EngineAvailability) -> some View {
        LabeledContent("Signatures") {
            if let age = availability.signatureAge {
                let days = Int(age / 86_400)
                Label(
                    days == 0 ? "updated today" : "\(days) day\(days == 1 ? "" : "s") old",
                    systemImage: availability.signaturesStale
                        ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(availability.signaturesStale ? .orange : .green)
            } else {
                Label("age unknown", systemImage: "questionmark.circle")
                    .foregroundStyle(.orange)
            }
        }
        if availability.signaturesStale {
            Text("Stale signatures give false confidence — run `freshclam` (or start the freshclam service) to update.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: Paths

    private var pathsSection: some View {
        Section("Paths to scan") {
            ForEach(scanner.paths, id: \.self) { path in
                HStack {
                    Text(path).font(.callout.monospaced())
                    Spacer()
                    Button {
                        scanner.removePath(path)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(scanner.isScanning)
                }
            }
            Button("Add folder…") { showingPathPicker = true }
                .disabled(scanner.isScanning)
        }
    }

    // MARK: Schedule

    @ViewBuilder
    private func scheduleSection(scanner: Bindable<ScanController>) -> some View {
        Section("Schedule") {
            Toggle("Scan automatically", isOn: scanner.scheduleEnabled)
            Picker("Frequency", selection: scanner.frequency) {
                ForEach(ScanController.Frequency.allCases) { frequency in
                    Text(frequency.label).tag(frequency)
                }
            }
            .disabled(!self.scanner.scheduleEnabled)

            if let lastRun = self.scanner.lastScheduledRun {
                LabeledContent(
                    "Last scheduled scan",
                    value: lastRun.formatted(date: .abbreviated, time: .shortened))
            } else if self.scanner.scheduleEnabled {
                Text("First scheduled scan starts within 15 minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Scheduled scans run while xVigil is running — pair with \"Start at login\" (Protection Status pane) for continuous coverage. Findings light up the menu bar shield.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Results

    @ViewBuilder
    private var resultsSection: some View {
        Section("Scan") {
            HStack {
                if scanner.isScanning {
                    Button(role: .cancel) {
                        scanner.stopScan()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    ProgressView().controlSize(.small)
                    Text(scanner.statusLine ?? "Scanning…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Button {
                        scanner.startManualScan()
                    } label: {
                        Label("Start scan", systemImage: "magnifyingglass.circle.fill")
                    }
                    .disabled(scanner.engineAvailability?.installed != true || scanner.paths.isEmpty)
                }
                Spacer()
            }

            ForEach(scanner.threats) { threat in
                HStack {
                    Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(threat.title).font(.callout.weight(.semibold)).foregroundStyle(.red)
                        Text(threat.detail)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    if let path = threat.path {
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: path)])
                        }
                        .font(.caption)
                    }
                }
            }

            if let summary = scanner.summary {
                summaryRow(summary)
            }
        }
    }

    @ViewBuilder
    private func summaryRow(_ summary: ScanSummary) -> some View {
        let origin = scanner.lastRunWasScheduled ? " (scheduled)" : ""
        if let errorMessage = summary.errorMessage {
            Label(errorMessage, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.callout)
        } else if summary.infectedCount == 0 {
            Label {
                Text("Clean — no threats found"
                    + (summary.scannedCount.map { " in \($0) files" } ?? "")
                    + String(format: " (%.0fs)", summary.duration) + origin)
            } icon: {
                Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
            }
        } else {
            Label {
                Text("\(summary.infectedCount) threat\(summary.infectedCount == 1 ? "" : "s") found"
                    + String(format: " (%.0fs)", summary.duration) + origin
                    + " — report only, nothing was removed")
            } icon: {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.red)
            }
            .font(.callout.weight(.semibold))
        }
    }
}
