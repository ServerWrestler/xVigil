import SwiftUI
import xVigilCore

struct DashboardView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                ForEach(DashboardModel.Section.allCases, id: \.self) { section in
                    Label(section.rawValue, systemImage: icon(for: section))
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } content: {
            Group {
                switch model.section {
                case .quarantine:
                    QuarantineListView(model: model)
                case .activity:
                    ActivityListView(model: model)
                case .status:
                    StatusPaneView(model: model)
                }
            }
            .navigationSplitViewColumnWidth(min: 320, ideal: 380)
        } detail: {
            switch model.section {
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
            case .status:
                placeholder("Protection status")
            }
        }
        .navigationTitle("xVigil")
        .frame(minWidth: 800, minHeight: 480)
    }

    private var sidebarSelection: Binding<DashboardModel.Section?> {
        Binding(
            get: { model.section },
            set: { if let section = $0 { model.section = section } }
        )
    }

    private func icon(for section: DashboardModel.Section) -> String {
        switch section {
        case .quarantine: "tray.full"
        case .activity: "waveform.path.ecg"
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
