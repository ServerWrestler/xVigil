import SwiftUI
import xVigilCore

struct MenuBarView: View {
    let model: VigilModel
    let dashboard: DashboardModel
    let monitor: DetectionMonitor
    let updates: UpdateChecker
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if monitor.count > 0 {
                detectionsBanner
            }
            if let release = updates.available {
                updateBanner(release)
            }
            Divider()
            statusSection
            Divider()
            quarantineSection
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { Task { model.refresh() } }
    }

    private var header: some View {
        HStack {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(.tint)
            Text("xVigil")
                .font(.headline)
            Spacer()
            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
        }
    }

    /// The loud part: a detection is never just a badge buried in a list.
    private var detectionsBanner: some View {
        Button {
            dashboard.section = .detections
            openWindow(id: "dashboard")
            NSApplication.shared.activate()
        } label: {
            HStack {
                Image(systemName: "exclamationmark.shield.fill")
                Text("\(monitor.count) possible detection\(monitor.count == 1 ? "" : "s") — click to review")
                    .font(.callout.weight(.semibold))
                Spacer()
            }
            .padding(8)
            .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(.red)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Blue, not red: an update is news, not an alarm.
    private func updateBanner(_ release: UpdateCheck.Release) -> some View {
        Button {
            NSWorkspace.shared.open(release.url)
        } label: {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                Text("xVigil \(release.version) available — view release")
                    .font(.callout.weight(.medium))
                Spacer()
            }
            .padding(8)
            .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(.blue)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            statusRow(
                label: "Gatekeeper",
                value: model.status?.gatekeeperEnabled == true ? "Enabled" : "Disabled",
                healthy: model.status?.gatekeeperEnabled == true
            )
            statusRow(
                label: "XProtect definitions",
                value: model.status?.xprotectVersion.map { "v\($0)" } ?? "Unknown",
                healthy: model.status?.xprotectVersion != nil
            )
            statusRow(
                label: "XProtect Remediator",
                value: model.status?.remediatorVersion.map { "v\($0)" } ?? "Not found",
                healthy: model.status?.remediatorVersion != nil
            )
        }
    }

    private func statusRow(label: String, value: String, healthy: Bool) -> some View {
        HStack {
            Image(systemName: healthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(healthy ? .green : .orange)
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.callout)
    }

    private var quarantineSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent quarantine events")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(model.totalEventCount) total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if model.recentEvents.isEmpty {
                Text("No quarantine events found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.recentEvents.prefix(10)) { event in
                            Button {
                                openDashboard(selecting: event)
                            } label: {
                                eventRow(event)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Open in dashboard")
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }

    private func eventRow(_ event: QuarantineEvent) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(event.agentName ?? "Unknown agent")
                    .font(.callout.weight(.medium))
                Spacer()
                if let timestamp = event.timestamp {
                    Text(timestamp, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 4) {
                Text(event.kindLabel)
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                if let url = event.dataURL ?? event.originURL {
                    Text(url)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Dashboard…") {
                openDashboard(selecting: nil)
            }
            .font(.caption)
            Spacer()
            if let lastRefreshed = model.lastRefreshed {
                Text("Updated \(lastRefreshed, format: .dateTime.hour().minute().second())")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .font(.caption)
        }
    }

    private func openDashboard(selecting event: QuarantineEvent?) {
        if let event {
            dashboard.select(event)
        }
        openWindow(id: "dashboard")
        // Accessory apps don't come forward on their own.
        NSApplication.shared.activate()
    }
}
