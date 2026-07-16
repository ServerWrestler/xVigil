import SwiftUI
import UniformTypeIdentifiers
import xVigilCore
import xVigilScan

struct ScanPaneView: View {
    @Bindable var model: DashboardModel
    @State private var showingPathPicker = false

    var body: some View {
        Form {
            engineSection
            pathsSection
            resultsSection
        }
        .formStyle(.grouped)
        .onAppear {
            if model.engineAvailability == nil { model.checkEngine() }
        }
        .fileImporter(
            isPresented: $showingPathPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            for url in (try? result.get()) ?? [] {
                model.addScanPath(url)
            }
        }
    }

    // MARK: Engine status

    @ViewBuilder
    private var engineSection: some View {
        Section("Engine") {
            if let availability = model.engineAvailability {
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
                Button("Re-check") { model.checkEngine() }
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
            ForEach(model.scanPaths, id: \.self) { path in
                HStack {
                    Text(path).font(.callout.monospaced())
                    Spacer()
                    Button {
                        model.removeScanPath(path)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.scanIsRunning)
                }
            }
            Button("Add folder…") { showingPathPicker = true }
                .disabled(model.scanIsRunning)
        }
    }

    // MARK: Results

    @ViewBuilder
    private var resultsSection: some View {
        Section("Scan") {
            HStack {
                if model.scanIsRunning {
                    Button(role: .cancel) {
                        model.stopScan()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    ProgressView().controlSize(.small)
                    Text(model.scanStatusLine ?? "Scanning…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Button {
                        model.startScan()
                    } label: {
                        Label("Start scan", systemImage: "magnifyingglass.circle.fill")
                    }
                    .disabled(model.engineAvailability?.installed != true || model.scanPaths.isEmpty)
                }
                Spacer()
            }

            ForEach(model.scanThreats) { threat in
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

            if let summary = model.scanSummary {
                summaryRow(summary)
            }
        }
    }

    @ViewBuilder
    private func summaryRow(_ summary: ScanSummary) -> some View {
        if let errorMessage = summary.errorMessage {
            Label(errorMessage, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.callout)
        } else if summary.infectedCount == 0 {
            Label {
                Text("Clean — no threats found"
                    + (summary.scannedCount.map { " in \($0) files" } ?? "")
                    + String(format: " (%.0fs)", summary.duration))
            } icon: {
                Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
            }
        } else {
            Label {
                Text("\(summary.infectedCount) threat\(summary.infectedCount == 1 ? "" : "s") found"
                    + String(format: " (%.0fs)", summary.duration)
                    + " — report only, nothing was removed")
            } icon: {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.red)
            }
            .font(.callout.weight(.semibold))
        }
    }
}
