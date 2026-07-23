import SwiftUI
import xVigilCore

struct QuarantineDetailView: View {
    let event: QuarantineEvent
    let model: DashboardModel

    var body: some View {
        Form {
            recordSection
            enrichmentSection
            relatedLogsSection
        }
        .formStyle(.grouped)
        .navigationSubtitle(event.agentName ?? "Quarantine event")
        // .id(event.id) resets scroll and task state per event; the model
        // caches results so revisiting an event is instant.
        .id(event.id)
        .task {
            model.enrichIfNeeded(event)
            model.loadRelatedLogsIfNeeded(for: event)
        }
    }

    // MARK: Database record

    private var recordSection: some View {
        Section("Event record") {
            CopyableRow(label: "Agent", value: event.agentName ?? "—")
            if let bundleID = event.agentBundleIdentifier {
                CopyableRow(label: "Bundle ID", value: bundleID)
            }
            LabeledContent("Type", value: event.kindLabel)
            if let timestamp = event.timestamp {
                LabeledContent(
                    "Date",
                    value: timestamp.formatted(date: .abbreviated, time: .standard))
            }
            if let dataURL = event.dataURL {
                CopyableRow(label: "Data URL", value: dataURL)
            }
            if let originURL = event.originURL {
                CopyableRow(label: "Origin URL", value: originURL)
            }
            if let senderName = event.senderName {
                CopyableRow(label: "Sender", value: senderName)
            }
            if let senderAddress = event.senderAddress {
                CopyableRow(label: "Sender address", value: senderAddress)
            }
            CopyableRow(label: "Event ID", value: event.id)
        }
    }

    // MARK: On-disk evidence

    @ViewBuilder
    private var enrichmentSection: some View {
        Section("On disk") {
            switch model.enrichments[event.id] {
            case nil, .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching for the file…")
                        .foregroundStyle(.secondary)
                }
            case .loaded(let enrichment):
                enrichmentRows(enrichment)
            }
        }
    }

    @ViewBuilder
    private func enrichmentRows(_ enrichment: EventEnrichment) -> some View {
        switch enrichment.fileStatus {
        case .notFound:
            Label {
                Text(enrichment.searchNotes.isEmpty
                    ? "File not found — likely deleted or moved. This is normal for older events."
                    : "File not found in the locations that could be searched.")
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "questionmark.folder")
            }
            searchNoteRows(enrichment.searchNotes)
        case .found(let path):
            CopyableRow(label: "File", value: path)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }

            if let assessment = enrichment.assessment {
                LabeledContent("Gatekeeper today") {
                    Label(
                        assessment.accepted ? "Would allow" : "Would block",
                        systemImage: assessment.accepted
                            ? "checkmark.seal.fill" : "xmark.seal.fill"
                    )
                    .foregroundStyle(assessment.accepted ? .green : .red)
                }
                if !assessment.detail.isEmpty {
                    Text(assessment.detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            if let signature = enrichment.signature {
                signatureRows(signature)
            }
        }
    }

    @ViewBuilder
    private func searchNoteRows(_ notes: [String]) -> some View {
        ForEach(notes, id: \.self) { note in
            Label {
                Text(note).font(.caption)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func signatureRows(_ signature: CodeSignature) -> some View {
        switch signature.status {
        case .signed:
            LabeledContent("Signature") {
                Label("Signed", systemImage: "checkmark.shield")
                    .foregroundStyle(.green)
            }
            ForEach(signature.authorities, id: \.self) { authority in
                Text(authority)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        case .unsigned:
            LabeledContent("Signature") {
                Text("Not code-signed (normal for documents and archives)")
                    .foregroundStyle(.secondary)
            }
        case .invalid:
            LabeledContent("Signature") {
                Label("Invalid", systemImage: "exclamationmark.shield.fill")
                    .foregroundStyle(.red)
            }
            if let problem = signature.problem {
                Text(problem)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Log context

    @ViewBuilder
    private var relatedLogsSection: some View {
        Section("XProtect activity around this event (±60s)") {
            if event.timestamp == nil {
                Text("No timestamp on this event, so log context is unavailable.")
                    .foregroundStyle(.secondary)
            } else {
                switch model.relatedLogs[event.id] {
                case nil, .loading:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Querying the unified log — can take a minute for older events…")
                            .foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    Text(message).foregroundStyle(.red)
                case .loaded(let entries) where entries.isEmpty:
                    Text("No entries — the log archive may not reach back this far (it typically holds a few days).")
                        .foregroundStyle(.secondary)
                case .loaded(let entries):
                    ForEach(entries.suffix(50)) { entry in
                        LogEntryRow(entry: entry)
                    }
                }
            }
        }
    }
}

/// Compact unified-log entry row shared by detail panes.
struct LogEntryRow: View {
    let entry: XProtectLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                if let date = entry.date {
                    Text(date, format: .dateTime.hour().minute().second())
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(entry.process)
                    .font(.caption2.weight(.medium))
                if entry.kind != .activity {
                    Text(entry.kind.label)
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .background(badgeColor.opacity(0.2), in: Capsule())
                        .foregroundStyle(badgeColor)
                }
            }
            Text(entry.message)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(4)
        }
        .padding(.vertical, 1)
    }

    private var badgeColor: Color {
        switch entry.kind {
        case .detection: .red
        case .assessment: .orange
        case .scan: .blue
        case .activity: .secondary
        }
    }
}
