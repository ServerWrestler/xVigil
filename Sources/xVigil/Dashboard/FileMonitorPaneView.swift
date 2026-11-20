import SwiftUI
import xVigilCore

struct FileMonitorPaneView: View {
    let model: DashboardModel
    @State private var showingAddSheet = false
    @State private var editingEntry: WatchlistEntry?
    @State private var inspectedEntry: WatchlistEntry?
    @State private var confirmingStopFollowing = false

    var body: some View {
        @Bindable var watchlist = model.watchlist
        Form {
            entriesSection
            remoteSection(watchlist: $watchlist)
            checkSection
            if !watchlist.allFindings.isEmpty {
                resultsSection
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingAddSheet) {
            WatchlistEntryEditor(title: "Add entry") { entry in
                model.watchlist.addEntry(entry)
            }
        }
        .sheet(item: $editingEntry) { entry in
            WatchlistEntryEditor(title: "Edit entry", entry: entry) { updated in
                model.watchlist.updateEntry(updated)
            }
        }
        .sheet(item: $inspectedEntry) { entry in
            WatchlistEntryDetail(entry: entry, state: watchlist.state(for: entry))
        }
        #if DEBUG
            .task {
                // Debug harness: render the detail sheet without a click.
                if ProcessInfo.processInfo.environment["XVIGIL_UITEST_FILEMONITOR"] == "inspect" {
                    try? await Task.sleep(for: .seconds(1))
                    inspectedEntry = watchlist.entries.first
                }
            }
        #endif
    }

    private var watchlist: WatchlistController { model.watchlist }

    // MARK: Entries

    private var entriesSection: some View {
        Section("Entries") {
            if watchlist.entries.isEmpty {
                Text("No entries yet. Add a file, folder, or glob pattern to watch — or configure a remote feed below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(watchlist.entries) { entry in
                entryRow(entry)
            }
            Button("Add entry…") { showingAddSheet = true }
                .disabled(watchlist.isChecking)
            if let storeError = watchlist.storeError {
                Text(storeError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func entryRow(_ entry: WatchlistEntry) -> some View {
        HStack(alignment: .firstTextBaseline) {
            // The whole text area opens the entry's details.
            Button {
                inspectedEntry = entry
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(entry.label).font(.callout.weight(.medium))
                            sourceBadge(entry.source)
                        }
                        Text(entry.target)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(summary(for: entry))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show details")
            statusIcon(for: entry)
            if entry.source.isLocal {
                Button {
                    editingEntry = entry
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .disabled(watchlist.isChecking)
                .help("Edit")
                Button {
                    watchlist.removeEntry(entry)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(watchlist.isChecking)
                .help("Remove")
            }
        }
    }

    private func sourceBadge(_ source: WatchlistEntry.Source) -> some View {
        let text: String
        switch source {
        case .local: text = "local"
        case .remote(let url): text = URL(string: url)?.host() ?? "remote"
        }
        return Text(text)
            .font(.caption2)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }

    private func summary(for entry: WatchlistEntry) -> String {
        var parts: [String] = []
        if entry.recursive { parts.append("recursive") }
        if entry.trackIntegrity { parts.append("integrity") }
        if !entry.contentPatterns.isEmpty {
            parts.append("\(entry.contentPatterns.count) pattern\(entry.contentPatterns.count == 1 ? "" : "s")")
        }
        parts.append("alerts: " + entry.alertConditions.map(\.label).joined(separator: ", "))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func statusIcon(for entry: WatchlistEntry) -> some View {
        if let state = watchlist.state(for: entry) {
            let alerts = state.findings.filter(\.isAlert).count
            if alerts > 0 {
                Label("\(alerts)", systemImage: "exclamationmark.shield.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help(state.lastChecked.map {
                        "Checked \($0.formatted(date: .abbreviated, time: .shortened))"
                    } ?? "Checked")
            }
        } else {
            Image(systemName: "circle.dotted")
                .foregroundStyle(.secondary)
                .help("Not checked yet")
        }
    }

    // MARK: Remote source

    @ViewBuilder
    private func remoteSection(watchlist bindable: Bindable<WatchlistController>) -> some View {
        Section("Remote source") {
            TextField("Feed URL (https)", text: bindable.remoteURL, prompt: Text("https://example.com/watchlist.json"))
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .autocorrectionDisabled()

            HStack(spacing: 8) {
                Button("Fetch now") {
                    Task { await watchlist.fetchRemote() }
                }
                .disabled(watchlist.isFetching || watchlist.isChecking || watchlist.remoteURL.isEmpty)
                if watchlist.isFetching {
                    ProgressView().controlSize(.small)
                }
                Button("Stop following…") {
                    confirmingStopFollowing = true
                }
                .disabled(watchlist.isFetching || watchlist.isChecking
                    || (watchlist.remoteURL.isEmpty && watchlist.remoteEntryCount == 0))
                .confirmationDialog(
                    "Stop following this feed?",
                    isPresented: $confirmingStopFollowing
                ) {
                    Button("Stop Following", role: .destructive) {
                        watchlist.stopFollowingFeed()
                    }
                } message: {
                    Text(stopFollowingMessage)
                }
                Spacer()
                if let lastFetch = watchlist.lastFetch {
                    Text("fetched \(lastFetch.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let fetchError = watchlist.fetchError {
                Text(fetchError).font(.caption).foregroundStyle(.red)
            }

            Toggle("Refresh and check automatically", isOn: bindable.autoRefresh)
            Picker("Frequency", selection: bindable.refreshFrequency) {
                ForEach(WatchlistController.Frequency.allCases) { frequency in
                    Text(frequency.label).tag(frequency)
                }
            }
            .disabled(!watchlist.autoRefresh)

            Text("Feeds are fetched over HTTPS only and treated as untrusted: entry counts, pattern counts, and pattern sizes are capped, and remote entries can never masquerade as local ones. Fetching a different URL replaces the previous feed's entries. Local entries always survive.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var stopFollowingMessage: String {
        let count = watchlist.remoteEntryCount
        let entries = count == 1 ? "1 feed entry" : "\(count) feed entries"
        return "Clears the feed URL and removes \(entries) with their baselines and alerts. Your local entries stay."
    }

    // MARK: Check

    private var checkSection: some View {
        Section("Check") {
            HStack(spacing: 8) {
                if watchlist.isChecking {
                    Button(role: .cancel) {
                        watchlist.stopCheck()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    ProgressView().controlSize(.small)
                    if let progress = watchlist.checkProgress {
                        Text("Checking \(progress.checked)/\(progress.total)…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        watchlist.checkNow()
                    } label: {
                        Label("Check now", systemImage: "eye.circle.fill")
                    }
                    .disabled(watchlist.entries.isEmpty)
                }
                Spacer()
                if let lastCheck = watchlist.lastCheck {
                    Text("checked \(lastCheck.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let checkError = watchlist.checkError {
                Text(checkError).font(.caption).foregroundStyle(.red)
            }
            Text("Checks are report-only: nothing is modified, quarantined, or deleted. Alerting findings light up the menu bar shield.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Results

    private var resultsSection: some View {
        Section("Results") {
            ForEach(watchlist.allFindings, id: \.finding.id) { item in
                findingRow(item.entry, item.finding)
            }
        }
    }

    private func findingRow(_ entry: WatchlistEntry, _ finding: WatchlistFinding) -> some View {
        HStack {
            Image(systemName: finding.isAlert
                ? "exclamationmark.shield.fill"
                : (finding.error != nil ? "questionmark.circle" : "info.circle"))
                .foregroundStyle(finding.isAlert ? .red : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(finding.path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(entry.label) — \(finding.reasons.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(finding.isAlert ? .red : .secondary)
            }
            Spacer()
            if finding.exists {
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: finding.path)])
                }
                .font(.caption)
            }
        }
    }
}

/// Read-only details for one entry: everything it is configured with plus
/// its latest results. Mostly for feed entries, whose notes carry severity,
/// MITRE IDs and known false positives but which can't be opened in the
/// editor.
private struct WatchlistEntryDetail: View {
    let entry: WatchlistEntry
    let state: WatchlistCheckState?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(entry.label)
                .font(.headline)
                .textSelection(.enabled)
                .padding()
            Form {
                Section("Notes") {
                    Text(entry.notes ?? "No notes.")
                        .foregroundStyle(entry.notes == nil ? .secondary : .primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section("Entry") {
                    LabeledContent("Target") {
                        Text(entry.target)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                    LabeledContent("Source") {
                        switch entry.source {
                        case .local:
                            Text("Local (yours)")
                        case .remote(let url):
                            Text(url)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    LabeledContent("Recursive", value: entry.recursive ? "Yes" : "No")
                    LabeledContent("Track integrity", value: entry.trackIntegrity ? "Yes (SHA-256)" : "No")
                    LabeledContent("Alert when",
                        value: entry.alertConditions.map(\.label).joined(separator: ", "))
                }
                if !entry.contentPatterns.isEmpty {
                    Section("Content patterns") {
                        ForEach(Array(entry.contentPatterns.enumerated()), id: \.offset) { _, pattern in
                            Text(pattern)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Section("Last check") {
                    if let state {
                        Text(state.lastChecked.map {
                            "Checked \($0.formatted(date: .abbreviated, time: .shortened))"
                        } ?? "Checked")
                        .foregroundStyle(.secondary)
                        if state.findings.isEmpty {
                            Text("Nothing matched the target.").foregroundStyle(.secondary)
                        }
                        ForEach(state.findings) { finding in
                            HStack(alignment: .firstTextBaseline) {
                                Image(systemName: finding.isAlert
                                    ? "exclamationmark.shield.fill" : "info.circle")
                                    .foregroundStyle(finding.isAlert ? .red : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(finding.path)
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                    Text(finding.reasons.joined(separator: ", "))
                                        .font(.caption2)
                                        .foregroundStyle(finding.isAlert ? .red : .secondary)
                                }
                            }
                        }
                    } else {
                        Text("Not checked yet.").foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 560, height: 560)
    }
}

/// Add/edit sheet for a local watchlist entry.
private struct WatchlistEntryEditor: View {
    let title: String
    var entry: WatchlistEntry?
    let onSave: (WatchlistEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var target = ""
    @State private var label = ""
    @State private var notes = ""
    @State private var recursive = false
    @State private var trackIntegrity = false
    @State private var patternsText = ""
    @State private var alertConditions: Set<AlertCondition> = [.onPresence]
    /// Tracks whether the user has manually touched the alert checkboxes;
    /// until they do, the selection follows the documented defaulting rule.
    @State private var alertsCustomized = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.headline).padding()
            Form {
                Section("Target") {
                    TextField("Path or glob", text: $target,
                        prompt: Text("~/Library/LaunchAgents/*.plist"))
                        .font(.callout.monospaced())
                        .autocorrectionDisabled()
                    TextField("Label", text: $label)
                    TextField("Notes (optional)", text: $notes)
                    Toggle("Recursive (directories and globs)", isOn: $recursive)
                }
                Section("Checks") {
                    Toggle("Track integrity (SHA-256)", isOn: $trackIntegrity)
                        .onChange(of: trackIntegrity) { applyDefaultAlertsIfUntouched() }
                    TextField("Content patterns (regex, one per line)",
                        text: $patternsText, axis: .vertical)
                        .font(.callout.monospaced())
                        .lineLimit(3...6)
                        .autocorrectionDisabled()
                        .onChange(of: patternsText) { applyDefaultAlertsIfUntouched() }
                }
                Section("Alert when") {
                    ForEach(AlertCondition.allCases, id: \.self) { condition in
                        Toggle(condition.label, isOn: alertBinding(condition))
                    }
                    Text("A plain existence entry alerts when the file is found (IOC-style).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(buildEntry())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 480, height: 520)
        .onAppear { populate() }
    }

    private func populate() {
        guard let entry else { return }
        target = entry.target
        label = entry.label
        notes = entry.notes ?? ""
        recursive = entry.recursive
        trackIntegrity = entry.trackIntegrity
        patternsText = entry.contentPatterns.joined(separator: "\n")
        alertConditions = Set(entry.alertConditions)
        alertsCustomized = true
    }

    private var patterns: [String] {
        patternsText.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func applyDefaultAlertsIfUntouched() {
        guard !alertsCustomized else { return }
        alertConditions = Set(WatchlistEntry.defaultAlertConditions(
            trackIntegrity: trackIntegrity, contentPatterns: patterns))
    }

    private func alertBinding(_ condition: AlertCondition) -> Binding<Bool> {
        Binding(
            get: { alertConditions.contains(condition) },
            set: { include in
                alertsCustomized = true
                if include { alertConditions.insert(condition) }
                else { alertConditions.remove(condition) }
            }
        )
    }

    private func buildEntry() -> WatchlistEntry {
        let trimmedTarget = target.trimmingCharacters(in: .whitespaces)
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespaces)
        // Preserve identity on edit so check state (baselines) carries over.
        return WatchlistEntry(
            id: entry?.id ?? UUID(),
            target: trimmedTarget,
            label: trimmedLabel.isEmpty ? trimmedTarget : trimmedLabel,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
            source: .local,
            recursive: recursive,
            trackIntegrity: trackIntegrity,
            contentPatterns: patterns,
            alertConditions: AlertCondition.allCases.filter(alertConditions.contains))
    }
}
