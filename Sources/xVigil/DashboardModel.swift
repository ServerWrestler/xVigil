import Foundation
import Observation
import xVigilCore

/// State for the dashboard window: filterable quarantine browsing with
/// keyset pagination, per-event enrichment, and grouped XProtect activity.
@MainActor
@Observable
final class DashboardModel {
    enum Section: String, Hashable, CaseIterable {
        case quarantine = "Quarantine Events"
        case activity = "XProtect Activity"
        case status = "Protection Status"
    }

    enum EnrichmentState {
        case loading
        case loaded(EventEnrichment)
    }

    enum RelatedLogsState {
        case loading
        case loaded([XProtectLogEntry])
        case failed(String)
    }

    nonisolated static let pageSize = 100

    var section: Section = .quarantine

    // MARK: Quarantine browsing

    private(set) var events: [QuarantineEvent] = []
    private(set) var agents: [String] = []
    private(set) var hasMore = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var selectedEvent: QuarantineEvent?

    var searchText: String = ""
    var agentFilter: String?
    var kindFilter: QuarantineEvent.Kind?

    /// Enrichment and related-log results, cached per event ID so selection
    /// changes never re-run the filesystem walk or log query.
    private(set) var enrichments: [String: EnrichmentState] = [:]
    private(set) var relatedLogs: [String: RelatedLogsState] = [:]

    // MARK: XProtect activity

    private(set) var activities: [XProtectActivity] = []
    private(set) var activitiesLoading = false
    private(set) var activitiesError: String?
    var activityWindow = "6h"
    var selectedActivityID: XProtectActivity.ID?

    var selectedActivity: XProtectActivity? {
        activities.first { $0.id == selectedActivityID }
    }

    // MARK: Status

    private(set) var status: SystemStatus?

    private let store = QuarantineStore()
    private var searchDebounce: Task<Void, Never>?

    // MARK: - Quarantine actions

    func loadInitialIfNeeded() {
        guard events.isEmpty && !isLoading else { return }
        reloadEvents()
        let store = self.store
        Task {
            self.agents = (try? await Task.detached { try store.distinctAgents() }.value) ?? []
        }
    }

    func filtersChanged(debounce: Bool = false) {
        searchDebounce?.cancel()
        guard debounce else {
            reloadEvents()
            return
        }
        searchDebounce = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self.reloadEvents()
        }
    }

    func reloadEvents() {
        isLoading = true
        errorMessage = nil
        let store = self.store
        let filter = currentFilter
        Task {
            do {
                let page = try await Task.detached {
                    try store.events(matching: filter, before: nil, limit: Self.pageSize)
                }.value
                // A newer filter change may have superseded this load.
                guard filter == self.currentFilter else { return }
                self.events = page
                self.hasMore = page.count == Self.pageSize
                // Keep the detail pane alive if the selected event survived the filter.
                if let selected = self.selectedEvent,
                    !page.contains(where: { $0.id == selected.id }) {
                    self.selectedEvent = nil
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isLoading = false
        }
    }

    func loadMore() {
        guard hasMore, !isLoading, let last = events.last?.timestamp else { return }
        isLoading = true
        let store = self.store
        let filter = currentFilter
        Task {
            do {
                let page = try await Task.detached {
                    try store.events(matching: filter, before: last, limit: Self.pageSize)
                }.value
                guard filter == self.currentFilter else { return }
                self.events.append(contentsOf: page)
                self.hasMore = page.count == Self.pageSize
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isLoading = false
        }
    }

    /// Select an event, including one arriving from the menu bar popover that
    /// may not be in the currently filtered list.
    func select(_ event: QuarantineEvent?) {
        selectedEvent = event
        section = .quarantine
    }

    func selectByID(_ id: String?) {
        selectedEvent = id.flatMap { id in events.first { $0.id == id } }
    }

    // MARK: - Enrichment

    func enrichIfNeeded(_ event: QuarantineEvent) {
        guard enrichments[event.id] == nil else { return }
        enrichments[event.id] = .loading
        let enricher = EventEnricher()
        Task {
            let enrichment = await Task.detached(priority: .utility) {
                enricher.enrich(event)
            }.value
            self.enrichments[event.id] = .loaded(enrichment)
        }
    }

    func loadRelatedLogsIfNeeded(for event: QuarantineEvent, window: TimeInterval = 60) {
        guard relatedLogs[event.id] == nil, let timestamp = event.timestamp else { return }
        relatedLogs[event.id] = .loading
        let reader = XProtectLogReader()
        Task {
            do {
                let entries = try await Task.detached(priority: .utility) {
                    try reader.entries(
                        from: timestamp.addingTimeInterval(-window),
                        to: timestamp.addingTimeInterval(window))
                }.value
                self.relatedLogs[event.id] = .loaded(entries)
            } catch {
                self.relatedLogs[event.id] = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - XProtect activity

    func loadActivitiesIfNeeded() {
        guard activities.isEmpty && !activitiesLoading else { return }
        loadActivities()
    }

    func loadActivities() {
        activitiesLoading = true
        activitiesError = nil
        let reader = XProtectLogReader()
        let window = activityWindow
        Task {
            do {
                let entries = try await Task.detached(priority: .userInitiated) {
                    try reader.entries(last: window)
                }.value
                guard window == self.activityWindow else { return }
                // Newest activity first.
                self.activities = XProtectActivityGrouper.group(entries).reversed()
                self.selectedActivityID = nil
            } catch {
                self.activitiesError = error.localizedDescription
            }
            self.activitiesLoading = false
        }
    }

    // MARK: - Status

    func refreshStatus() {
        Task {
            self.status = await Task.detached { SystemStatus.current() }.value
        }
    }

    private var currentFilter: QuarantineFilter {
        QuarantineFilter(agentName: agentFilter, kind: kindFilter, searchText: searchText)
    }
}
