import SwiftUI
import xVigilCore

struct QuarantineListView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            list
        }
        // Deferred: mutating list-driving state synchronously inside
        // onAppear re-enters NSTableView's update pass (reentrancy warning).
        .onAppear { Task { model.loadInitialIfNeeded() } }
    }

    private var filterBar: some View {
        VStack(spacing: 8) {
            TextField("Search URLs, senders, agents…", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .onChange(of: model.searchText) {
                    model.filtersChanged(debounce: true)
                }
            HStack {
                Picker("Agent", selection: $model.agentFilter) {
                    Text("All agents").tag(String?.none)
                    ForEach(model.agents, id: \.self) { agent in
                        Text(agent).tag(String?.some(agent))
                    }
                }
                Picker("Type", selection: $model.kindFilter) {
                    Text("All types").tag(QuarantineEvent.Kind?.none)
                    ForEach(QuarantineEvent.Kind.allCases.filter { $0 != .unknown }, id: \.self) {
                        Text($0.label).tag(QuarantineEvent.Kind?.some($0))
                    }
                }
            }
            .labelsHidden()
            .onChange(of: model.agentFilter) { model.filtersChanged() }
            .onChange(of: model.kindFilter) { model.filtersChanged() }
        }
        .padding(10)
    }

    private var list: some View {
        List(selection: listSelection) {
            if let errorMessage = model.errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            ForEach(model.events) { event in
                row(event)
                    .tag(event.id)
                    .onAppear {
                        if event.id == model.events.last?.id {
                            Task { model.loadMore() }
                        }
                    }
            }
            if model.isLoading {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
            } else if model.events.isEmpty {
                Text("No events match.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var listSelection: Binding<String?> {
        Binding(
            get: { model.selectedEvent?.id },
            set: { model.selectByID($0) }
        )
    }

    private func row(_ event: QuarantineEvent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(event.agentName ?? "Unknown agent")
                    .font(.body.weight(.medium))
                Spacer()
                if let timestamp = event.timestamp {
                    Text(timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                Text(event.kindLabel)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                if let detail = event.dataURL ?? event.originURL ?? event.senderName {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
