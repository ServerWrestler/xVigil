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

    // MARK: Detections

    var selectedFindingID: Finding.ID?

    // MARK: On-demand scan

    private(set) var engineAvailability: EngineAvailability?
    var scanPaths: [String] = DashboardModel.defaultScanPaths()
    private(set) var scanIsRunning = false
    private(set) var scanThreats: [Finding] = []
    private(set) var scanSummary: ScanSummary?
    private(set) var scanStatusLine: String?
    private var scanTask: Task<Void, Never>?

    // MARK: Status

    private(set) var status: SystemStatus?

    let monitor: DetectionMonitor
    private let store = QuarantineStore()
    private let engine = ClamAVEngine()
    private var searchDebounce: Task<Void, Never>?

    init(monitor: DetectionMonitor) {
        self.monitor = monitor
        // Headless self-check inside the real GUI process (debug builds only):
        //   XVIGIL_SMOKE=1 .build/debug/xVigil
        #if DEBUG
            if ProcessInfo.processInfo.environment["XVIGIL_SMOKE"] != nil {
                Task { await runSmokeTest() }
            }
        #endif
    }

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
                let entries = try await reader.entries(
                    from: timestamp.addingTimeInterval(-window),
                    to: timestamp.addingTimeInterval(window))
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

    // MARK: - On-demand scan

    static func defaultScanPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew", "/usr/local", home + "/Downloads"]
        return candidates.filter { FileManager.default.fileExists(atPath: $0) }
    }

    func checkEngine() {
        let engine = self.engine
        Task {
            self.engineAvailability = await engine.availability()
        }
    }

    func startScan() {
        guard !scanIsRunning, !scanPaths.isEmpty else { return }
        scanIsRunning = true
        scanThreats = []
        scanSummary = nil
        scanStatusLine = nil
        monitor.setScanFindings([])

        let engine = self.engine
        let urls = scanPaths.map { URL(fileURLWithPath: $0) }
        scanTask = Task {
            for await event in engine.scan(paths: urls) {
                switch event {
                case .started(let scanner, _):
                    self.scanStatusLine = "Scanning with \(scanner)…"
                case .threatFound(let path, let signature):
                    let finding = Finding(
                        source: .scan, date: Date(),
                        title: signature, detail: path, path: path)
                    self.scanThreats.append(finding)
                    self.monitor.setScanFindings(self.scanThreats)
                case .progress(let message):
                    self.scanStatusLine = message
                case .finished(let summary):
                    self.scanSummary = summary
                    self.scanStatusLine = nil
                }
            }
            self.scanIsRunning = false
            self.scanTask = nil
        }
    }

    func stopScan() {
        scanTask?.cancel()
    }

    func addScanPath(_ url: URL) {
        let path = url.path
        if !scanPaths.contains(path) { scanPaths.append(path) }
    }

    func removeScanPath(_ path: String) {
        scanPaths.removeAll { $0 == path }
    }

    // MARK: - Status

    func refreshStatus() {
        Task {
            self.status = await SystemStatus.load()
        }
    }

    private var currentFilter: QuarantineFilter {
        QuarantineFilter(agentName: agentFilter, kind: kindFilter, searchText: searchText)
    }

    // MARK: - Headless smoke test (XVIGIL_SMOKE=1, debug builds only)

    #if DEBUG
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

        let availability = await engine.availability()
        stamp("scan engine: installed=\(availability.installed)"
            + " daemon=\(availability.daemonRunning)"
            + " sigAge=\(availability.signatureAge.map { "\(Int($0 / 3600))h" } ?? "n/a")")

        var enrichDone = false
        var logsDone = false
        var activitiesDone = false
        while Date().timeIntervalSince(started) < 300 {
            try? await Task.sleep(for: .seconds(2))
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
            if enrichDone && logsDone && activitiesDone {
                stamp("SMOKE PASS")
                exit(0)
            }
        }
        stamp("SMOKE TIMEOUT — enrich:\(enrichDone) logs:\(logsDone) activities:\(activitiesDone)")
        exit(1)
    }
    #endif
}
