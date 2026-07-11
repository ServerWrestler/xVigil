import SwiftUI
import xVigilCore

struct ActivityListView: View {
    @Bindable var model: DashboardModel

    private static let windows = ["1h", "6h", "24h", "3d"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Window", selection: $model.activityWindow) {
                    ForEach(Self.windows, id: \.self) { Text("Last \($0)").tag($0) }
                }
                .labelsHidden()
                .onChange(of: model.activityWindow) { model.loadActivities() }
                Spacer()
                if model.activitiesLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        model.loadActivities()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(10)
            Divider()
            List(selection: $model.selectedActivityID) {
                if let error = model.activitiesError {
                    Text(error).foregroundStyle(.red)
                }
                ForEach(model.activities) { activity in
                    row(activity).tag(activity.id)
                }
                if model.activitiesLoading && model.activities.isEmpty {
                    Text("Querying the unified log — long windows can take a minute…")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else if !model.activitiesLoading && model.activities.isEmpty {
                    Text("No XProtect activity in this window.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { Task { model.loadActivitiesIfNeeded() } }
    }

    private func row(_ activity: XProtectActivity) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(activity.process)
                    .font(.body.weight(.medium))
                Spacer()
                if let start = activity.startDate {
                    Text(start, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                Text(activity.kind.label)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(color(for: activity.kind).opacity(0.2), in: Capsule())
                    .foregroundStyle(color(for: activity.kind))
                Text("\(activity.entries.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let start = activity.startDate, let end = activity.endDate, end > start {
                    Text(duration(from: start, to: end))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func color(for kind: XProtectLogEntry.Kind) -> Color {
        switch kind {
        case .detection: .red
        case .assessment: .orange
        case .scan: .blue
        case .activity: .secondary
        }
    }

    private func duration(from start: Date, to end: Date) -> String {
        let seconds = end.timeIntervalSince(start)
        return seconds < 60
            ? String(format: "%.0fs", seconds)
            : String(format: "%.1fm", seconds / 60)
    }
}

struct ActivityDetailView: View {
    let activity: XProtectActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            Divider()
            List(activity.entries) { entry in
                LogEntryRow(entry: entry)
            }
        }
        .navigationSubtitle(activity.process)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(activity.process).font(.title3.weight(.semibold))
                Spacer()
                Text(activity.kind.label)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            if let start = activity.startDate {
                Text(
                    "\(start.formatted(date: .abbreviated, time: .standard))"
                        + (activity.endDate.map {
                            " – \($0.formatted(date: .omitted, time: .standard))"
                        } ?? "")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            let flagged = activity.flaggedEntries
            if !flagged.isEmpty {
                Text("\(flagged.count) of \(activity.entries.count) entries flagged")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }
}
