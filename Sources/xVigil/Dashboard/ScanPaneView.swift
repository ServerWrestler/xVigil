import SwiftUI
import UniformTypeIdentifiers
import xVigilCore
import xVigilScan

struct ScanPaneView: View {
    let model: DashboardModel
    @State private var showingPathPicker = false
    @State private var confirmingStop = false

    var body: some View {
        @Bindable var scanner = model.scanner
        Form {
            engineSection
            pathsSection
            scheduleSection(scanner: $scanner)
            resultsSection
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Stop the update?", isPresented: $confirmingStop, titleVisibility: .visible
        ) {
            Button("Stop update", role: .destructive) { updater.stop() }
            Button("Keep running", role: .cancel) {}
        } message: {
            Text("Stopping Homebrew partway through an upgrade can leave ClamAV half-installed. If that happens, run `brew reinstall clamav`.")
        }
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
                        Text("ClamAV is not installed.")
                    } icon: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    }
                }
                Text(availability.detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                maintenanceControls
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking for ClamAV…").foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Engine maintenance

    private var updater: ClamAVUpdateController { scanner.updater }

    /// Re-check always; the update button only when Homebrew and ClamAV are
    /// both installed. Otherwise a plain text suggestion: xVigil never
    /// installs software itself.
    @ViewBuilder
    private var maintenanceControls: some View {
        HStack {
            Button("Re-check") { scanner.checkEngine() }
                .disabled(updater.isRunning)
            if updater.readiness == .ready {
                Button("Update ClamAV & signatures") { scanner.updateEngine() }
                    .disabled(updater.isRunning || scanner.isScanning)
                    .help("Runs brew update, brew upgrade clamav, then freshclam")
            }
            Spacer()
        }
        readinessMessage
        updateProgress
    }

    @ViewBuilder
    private var readinessMessage: some View {
        switch updater.readiness {
        case .ready:
            Text("Runs `brew update`, `brew upgrade clamav`, then `freshclam`. Only ClamAV is upgraded; other Homebrew packages are left alone. Needs a network connection.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .missing(let homebrewMissing, let clamavMissing):
            Text(missingMessage(homebrewMissing: homebrewMissing, clamavMissing: clamavMissing))
                .font(.caption)
                .foregroundStyle(.orange)
        case .needsConfig(let path):
            Text("freshclam has no configuration yet. Copy `freshclam.conf.sample` to `\(path)` and remove its `Example` line (`brew info clamav` shows how), then click Re-check.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func missingMessage(homebrewMissing: Bool, clamavMissing: Bool) -> LocalizedStringKey {
        switch (homebrewMissing, clamavMissing) {
        case (true, true):
            "Homebrew and ClamAV are not installed. Install [Homebrew](https://brew.sh), then run `brew install clamav` in Terminal. xVigil can then keep ClamAV up to date for you."
        case (true, false):
            "ClamAV is installed, but Homebrew isn't, so xVigil can't update it automatically. Install [Homebrew](https://brew.sh) to enable one-click updates."
        default:
            "ClamAV is not installed. Run `brew install clamav` in Terminal, then click Re-check."
        }
    }

    /// Step checklist, live log, and outcome of an update run.
    @ViewBuilder
    private var updateProgress: some View {
        if !updater.steps.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(updater.steps) { step in
                    Label {
                        Text(step.title).font(.callout.monospaced())
                    } icon: {
                        stepIcon(step.status)
                    }
                }
            }
            if updater.isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Button("Stop", role: .cancel) { confirmingStop = true }
                        .controlSize(.small)
                }
            }
            if !updater.logLines.isEmpty {
                DisclosureGroup("Output") {
                    ScrollView {
                        Text(updater.logLines.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                }
            }
            if let result = updater.result {
                Label(result.message, systemImage: result.succeeded
                    ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(result.succeeded ? .green : .red)
                    .font(.callout)
            }
        }
    }

    @ViewBuilder
    private func stepIcon(_ status: ClamAVUpdateController.StepState.Status) -> some View {
        switch status {
        case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.mini)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
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
            Text(updater.readiness == .ready
                ? "Stale signatures give false confidence. Click Update ClamAV & signatures above."
                : "Stale signatures give false confidence. Run `freshclam` to update.")
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
