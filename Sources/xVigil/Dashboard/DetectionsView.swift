import SwiftUI
import xVigilCore

struct DetectionsListView: View {
    @Bindable var model: DashboardModel
    let monitor: DetectionMonitor

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List(selection: $model.selectedFindingID) {
                if monitor.findings.isEmpty {
                    if monitor.isSweeping && monitor.lastSweep == nil {
                        Text("Sweeping the last 24h of XProtect logs…")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    } else {
                        Label("No detections", systemImage: "checkmark.shield")
                            .foregroundStyle(.green)
                    }
                }
                ForEach(monitor.findings) { finding in
                    row(finding).tag(finding.id)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            if monitor.count > 0 {
                Label("\(monitor.count) active finding\(monitor.count == 1 ? "" : "s")",
                    systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout.weight(.semibold))
            } else {
                Text("XProtect detections (last 24h) and scan results")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if monitor.isSweeping {
                ProgressView().controlSize(.small)
            } else {
                if let lastSweep = monitor.lastSweep {
                    Text("swept \(lastSweep, format: .dateTime.hour().minute())")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await monitor.sweep() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Sweep logs now")
            }
        }
        .padding(10)
    }

    private func row(_ finding: Finding) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.red)
                Text(finding.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Spacer()
            }
            HStack(spacing: 6) {
                Text(finding.source.label)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.red.opacity(0.15), in: Capsule())
                    .foregroundStyle(.red)
                if let date = finding.date {
                    Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct FindingDetailView: View {
    let finding: Finding

    var body: some View {
        Form {
            Section("Finding") {
                LabeledContent("Source", value: finding.source.label)
                if let date = finding.date {
                    LabeledContent("Date",
                        value: date.formatted(date: .abbreviated, time: .standard))
                }
                CopyableRow(label: "Summary", value: finding.title)
            }
            Section("Detail") {
                Text(finding.detail)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
            if let path = finding.path {
                Section("File") {
                    CopyableRow(label: "Path", value: path)
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: path)])
                    }
                    Text("xVigil reports only — it never quarantines or deletes. Review the file yourself before acting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
