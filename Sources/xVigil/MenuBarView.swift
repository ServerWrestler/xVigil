import SwiftUI
import xVigilCore

struct MenuBarView: View {
    let model: VigilModel
    let dashboard: DashboardModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            statusSection
            Divider()
            quarantineSection
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { model.refresh() }
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
                Text(event.kind.label)
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
