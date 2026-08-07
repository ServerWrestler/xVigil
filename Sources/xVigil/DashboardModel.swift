import AppKit
import Foundation
import Observation
import xVigilCore
import xVigilScan

/// State for the dashboard window: filterable quarantine browsing with
/// keyset pagination, per-event enrichment, and grouped XProtect activity.
@MainActor
@Observable
final class DashboardModel {
    enum Section: String, Hashable, CaseIterable {
        case detections = "Detections"
        case quarantine = "Quarantine Events"
        case activity = "XProtect Activity"
        case scan = "On-Demand Scan"
        case fileMonitor = "File Monitor"
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
    private(set) var typeNumbers: [Int] = []
    private(set) var hasMore = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var selectedEvent: QuarantineEvent?

    var searchText: String = ""
    var agentFilter: String?
    var typeFilter: Int?

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

    // MARK: Detections

    var selectedFindingID: Finding.ID?

    // MARK: Status

    private(set) var status: SystemStatus?

    let monitor: DetectionMonitor
    let scanner: ScanController
    let watchlist: WatchlistController
    private let store = QuarantineStore()
    private var searchDebounce: Task<Void, Never>?

    init(monitor: DetectionMonitor, scanner: ScanController, watchlist: WatchlistController) {
        self.monitor = monitor
        self.scanner = scanner
        self.watchlist = watchlist
        // Headless self-checks inside the real GUI process (debug builds only):
        //   XVIGIL_SMOKE=1 .build/debug/xVigil   — one event, all panes
        #if DEBUG
            if ProcessInfo.processInfo.environment["XVIGIL_SMOKE"] != nil {
                Task { await runSmokeTest() }
            }
            if ProcessInfo.processInfo.environment["XVIGIL_UITEST"] != nil {
                Task { await runUITest() }
            }
        #endif
    }

    // MARK: - Quarantine actions

    func loadInitialIfNeeded() {
        guard events.isEmpty && !isLoading else { return }
        reloadEvents()
        let store = self.store
        Task {
            let options = try? await Task.detached {
                (try store.distinctAgents(), try store.distinctTypeNumbers())
            }.value
            self.agents = options?.0 ?? []
            self.typeNumbers = options?.1 ?? []
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
        guard hasMore, !isLoading, let last = events.last, last.timestamp != nil else { return }
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
            // enrich() parks its blocking work on GCD itself.
            self.enrichments[event.id] = .loaded(await enricher.enrich(event))
        }
    }

    func loadRelatedLogsIfNeeded(for event: QuarantineEvent, window: TimeInterval = 60) {
        guard relatedLogs[event.id] == nil, let timestamp = event.timestamp else { return }
        relatedLogs[event.id] = .loading
        let reader = XProtectLogReader()
        Task {
            do {
                // A ±60s window is small; cap at 45s so a slow archive scan
                // fails visibly instead of spinning toward the 120s default.
                let entries = try await reader.entries(
                    from: timestamp.addingTimeInterval(-window),
                    to: timestamp.addingTimeInterval(window),
                    timeout: 45)
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
                let entries = try await reader.entries(last: window)
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
            self.status = await SystemStatus.load()
        }
    }

    private var currentFilter: QuarantineFilter {
        QuarantineFilter(agentName: agentFilter, typeNumber: typeFilter, searchText: searchText)
    }

    // MARK: - Headless smoke test (XVIGIL_SMOKE=1, debug builds only)

    #if DEBUG
    /// Unbuffered debug output, so a running app's log survives redirection.
    nonisolated static func trace(_ message: String) {
        FileHandle.standardError.write(Data("[trace] \(message)\n".utf8))
    }

    /// Selects a real event so the REAL SwiftUI detail pane renders and fires
    /// its own `.task` (no model calls faked here), then logs model state
    /// every second. Pair with a screenshot: if the model reports `.loaded`
    /// while the window still shows a spinner, the bug is in the view layer,
    /// not the async work. The app stays alive for inspection.
    private func runUITest() async {
        let started = Date()
        func stamp(_ message: String) {
            Self.trace(String(format: "[ui %5.1fs] %@", Date().timeIntervalSince(started), message))
        }
        // Click through a spread of real events — including older ones whose
        // files are long gone, which is the user's reported failure case.
        guard let candidates = try? store.recentEvents(limit: 60), !candidates.isEmpty else {
            stamp("no events"); return
        }
        let sample = stride(from: 0, to: min(candidates.count, 60), by: 6).map { candidates[$0] }
        try? await Task.sleep(for: .seconds(2))  // let the window finish opening
        stamp("clicking \(sample.count) events with the window OPEN")

        var worst: TimeInterval = 0
        for (index, event) in sample.enumerated() {
            let clicked = Date()
            select(event)  // exactly what a row click does
            NSApplication.shared.activate(ignoringOtherApps: true)

            var enrichDone = false
            var logsDone = event.timestamp == nil
            while Date().timeIntervalSince(clicked) < 60 {
                if case .loaded = enrichments[event.id] { enrichDone = true }
                switch relatedLogs[event.id] {
                case .loaded, .failed: logsDone = true
                default: break
                }
                if enrichDone && logsDone { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            let elapsed = Date().timeIntervalSince(clicked)
            worst = max(worst, elapsed)
            let when = event.timestamp.map {
                $0.formatted(date: .abbreviated, time: .shortened)
            } ?? "no date"
            stamp(String(format: "%2d. %@ %@ — %.1fs %@",
                index + 1, when, event.id.prefix(8).description, elapsed,
                enrichDone && logsDone
                    ? "ok" : "HUNG (enrich:\(enrichDone) logs:\(logsDone))"))
        }
        stamp(String(format: "worst case %.1fs — window stays open for inspection", worst))
    }

    /// Exercises the exact model paths the detail pane uses, inside the real
    /// NSApplication process, then exits. Exists because the async plumbing
    /// (cooperative pool vs GCD) behaves differently in a GUI app than in
    /// the CLI harness. Compiled out of release builds.
    private func runSmokeTest() async {
        let started = Date()
        func stamp(_ message: String) {
            print(String(format: "[smoke %5.1fs] %@", Date().timeIntervalSince(started), message))
        }

        stamp("starting in-app smoke test")
        guard let event = try? store.recentEvents(limit: 1).first else {
            stamp("FAIL: quarantine database empty or unreadable")
            exit(1)
        }
        stamp("event: \(event.agentName ?? "?") \(event.id)")

        select(event)
        enrichIfNeeded(event)
        loadRelatedLogsIfNeeded(for: event)
        loadActivities()
        loadInitialIfNeeded()

        let availability = await ClamAVEngine().availability()
        stamp("scan engine: installed=\(availability.installed)"
            + " daemon=\(availability.daemonRunning)"
            + " sigAge=\(availability.signatureAge.map { "\(Int($0 / 3600))h" } ?? "n/a")")

        var enrichDone = false
        var logsDone = false
        var activitiesDone = false
        var listDone = false
        while Date().timeIntervalSince(started) < 300 {
            try? await Task.sleep(for: .seconds(2))
            if !listDone, !isLoading, !events.isEmpty {
                listDone = true
                stamp("quarantine list: \(events.count) events loaded, "
                    + "\(agents.count) agents, types \(typeNumbers.map(String.init).joined(separator: "/"))")
            }
            if !enrichDone, case .loaded(let enrichment)? = enrichments[event.id] {
                enrichDone = true
                stamp("enrichment finished: \(enrichment.fileStatus)")
            }
            if !logsDone {
                switch relatedLogs[event.id] {
                case .loaded(let entries)?:
                    logsDone = true
                    stamp("related logs finished: \(entries.count) entries")
                case .failed(let message)?:
                    logsDone = true
                    stamp("related logs failed (acceptable, not a hang): \(message)")
                default: break
                }
            }
            if !activitiesDone, !activitiesLoading {
                activitiesDone = true
                stamp("activities finished: \(activities.count) clusters"
                    + (activitiesError.map { " (error: \($0))" } ?? ""))
            }
            if enrichDone && logsDone && activitiesDone && listDone {
                stamp("SMOKE PASS")
                exit(0)
            }
        }
        stamp("SMOKE TIMEOUT — enrich:\(enrichDone) logs:\(logsDone) "
            + "activities:\(activitiesDone) list:\(listDone)")
        exit(1)
    }
    #endif
}
