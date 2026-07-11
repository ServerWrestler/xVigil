import SwiftUI
import xVigilCore

struct StatusPaneView: View {
    let model: DashboardModel

    var body: some View {
        Form {
            Section("Protection status") {
                statusRow(
                    label: "Gatekeeper",
                    value: model.status?.gatekeeperEnabled == true ? "Enabled" : "Disabled",
                    healthy: model.status?.gatekeeperEnabled == true)
                statusRow(
                    label: "XProtect definitions",
                    value: model.status?.xprotectVersion.map { "v\($0)" } ?? "Unknown",
                    healthy: model.status?.xprotectVersion != nil)
                statusRow(
                    label: "XProtect Remediator",
                    value: model.status?.remediatorVersion.map { "v\($0)" } ?? "Not found",
                    healthy: model.status?.remediatorVersion != nil)
            }
            Section {
                Button("Refresh") { model.refreshStatus() }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            Task { if model.status == nil { model.refreshStatus() } }
        }
    }

    private func statusRow(label: String, value: String, healthy: Bool) -> some View {
        LabeledContent(label) {
            Label(value, systemImage: healthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(healthy ? .green : .orange)
        }
    }
}
