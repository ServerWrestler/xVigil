import SwiftUI
import xVigilCore

struct StatusPaneView: View {
    let model: DashboardModel
    let updates: UpdateChecker
    @State private var loginEnabled = false
    @State private var loginError: String?

    var body: some View {
        @Bindable var updates = updates
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
            loginSection
            updatesSection(updates: $updates)
            Section {
                Button("Refresh") { model.refreshStatus() }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            loginEnabled = LoginItem.isEnabled
            Task { if model.status == nil { model.refreshStatus() } }
        }
    }

    @ViewBuilder
    private var loginSection: some View {
        Section("General") {
            if LoginItem.isSupported {
                Toggle("Start xVigil at login", isOn: loginBinding)
                if LoginItem.requiresApproval {
                    Text("Blocked in System Settings → General → Login Items — allow xVigil there.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("A monitor only protects you while it's running. This registers xVigil in System Settings → General → Login Items, where you can also revoke it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("Start at login") {
                    Text("Available from the installed xVigil.app (not `swift run`)")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func updatesSection(updates bindable: Bindable<UpdateChecker>) -> some View {
        Section("Updates") {
            Toggle("Check for updates automatically", isOn: bindable.enabled)
            Picker("Frequency", selection: bindable.frequency) {
                ForEach(UpdateChecker.Frequency.allCases) { frequency in
                    Text(frequency.label).tag(frequency)
                }
            }
            .disabled(!updates.enabled)

            if let release = updates.available {
                HStack {
                    Label("xVigil \(release.version) is available", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                    Spacer()
                    Button("View release") { NSWorkspace.shared.open(release.url) }
                }
            }

            HStack(spacing: 8) {
                Button("Check now") { updates.checkNow() }
                    .disabled(updates.isChecking)
                if updates.isChecking {
                    ProgressView().controlSize(.small)
                } else if let message = updates.statusMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let lastChecked = updates.lastChecked {
                    Text("checked \(lastChecked.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Checks the GitHub Releases page with a single anonymous request. Updates are never downloaded or installed automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { loginEnabled },
            set: { newValue in
                loginError = nil
                do {
                    try LoginItem.setEnabled(newValue)
                } catch {
                    loginError = error.localizedDescription
                }
                loginEnabled = LoginItem.isEnabled
            }
        )
    }

    private func statusRow(label: String, value: String, healthy: Bool) -> some View {
        LabeledContent(label) {
            Label(value, systemImage: healthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(healthy ? .green : .orange)
        }
    }
}
