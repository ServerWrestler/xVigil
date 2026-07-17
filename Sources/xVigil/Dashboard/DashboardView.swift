import SwiftUI
import xVigilCore

struct DashboardView: View {
    @Bindable var model: DashboardModel
    let monitor: DetectionMonitor

    var body: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                ForEach(DashboardModel.Section.allCases, id: \.self) { section in
                    sidebarRow(section)
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } content: {
            Group {
                switch model.section {
                case .detections:
                    DetectionsListView(model: model, monitor: monitor)
                case .quarantine:
                    QuarantineListView(model: model)
                case .activity:
                    ActivityListView(model: model)
                case .scan:
                    ScanPaneView(model: model)
                case .status:
                    StatusPaneView(model: model)
                }
            }
            .navigationSplitViewColumnWidth(min: 320, ideal: 400)
        } detail: {
            switch model.section {
            case .detections:
                if let finding = monitor.findings.first(where: { $0.id == model.selectedFindingID }) {
                    FindingDetailView(finding: finding)
                } else {
                    placeholder(monitor.count == 0
                        ? "No active findings"
                        : "Select a finding")
                }
            case .quarantine:
                if let event = model.selectedEvent {
                    QuarantineDetailView(event: event, model: model)
                } else {
                    placeholder("Select a quarantine event")
                }
            case .activity:
                if let activity = model.selectedActivity {
                    ActivityDetailView(activity: activity)
                } else {
                    placeholder("Select an activity")
                }
            case .scan:
                placeholder("On-demand scanning")
            case .status:
                placeholder("Protection status")
            }
        }
        .navigationTitle("xVigil")
        .frame(minWidth: 800, minHeight: 480)
        .onAppear { DockPresence.dashboardOpened() }
        .onDisappear { DockPresence.dashboardClosed() }
    }

    @ViewBuilder
    private func sidebarRow(_ section: DashboardModel.Section) -> some View {
        if section == .detections && monitor.count > 0 {
            Label(section.rawValue, systemImage: "exclamationmark.shield.fill")
                .foregroundStyle(.red)
                .badge(monitor.count)
        } else {
            Label(section.rawValue, systemImage: icon(for: section))
        }
    }

    private var sidebarSelection: Binding<DashboardModel.Section?> {
        Binding(
            get: { model.section },
            set: { if let section = $0 { model.section = section } }
        )
    }

    private func icon(for section: DashboardModel.Section) -> String {
        switch section {
        case .detections: "checkmark.shield"
        case .quarantine: "tray.full"
        case .activity: "waveform.path.ecg"
        case .scan: "magnifyingglass.circle"
        case .status: "shield.lefthalf.filled"
        }
    }

    private func placeholder(_ text: String) -> some View {
        ContentUnavailableView(text, systemImage: "sidebar.right")
    }
}

/// A label/value row with click-to-copy, used across detail panes.
struct CopyableRow: View {
    let label: String
    let value: String

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                Text(value)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.trailing)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
        }
    }
}
