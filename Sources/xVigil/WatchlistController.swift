import Foundation
import Observation
import xVigilCore

/// Owns the file watchlist: the merged entry list, per-entry check state,
/// remote feed refresh, and the check schedule loop. Lives at app scope
/// (not the dashboard) so scheduled checks run while the app sits in the
/// menu bar — same placement rationale as ScanController.
@MainActor
@Observable
final class WatchlistController {
    enum Frequency: String, CaseIterable, Identifiable {
        case hourly
        case daily

        var id: String { rawValue }
        var label: String {
            switch self {
            case .hourly: "Hourly"
            case .daily: "Daily"
            }
        }
        var seconds: TimeInterval {
            switch self {
            case .hourly: 3_600
            case .daily: 86_400
            }
        }
    }

    private(set) var entries: [WatchlistEntry] = []
    private(set) var checkState: [UUID: WatchlistCheckState] = [:]
    private(set) var isChecking = false
    private(set) var lastCheck: Date?
    private(set) var checkError: String?
    private(set) var checkProgress: (checked: Int, total: Int)?
    private(set) var isFetching = false
    private(set) var lastFetch: Date?
    private(set) var fetchError: String?
    /// Load/save problems worth surfacing in the pane.
    private(set) var storeError: String?

    var remoteURL: String {
        didSet { defaults.set(remoteURL, forKey: Keys.remoteURL) }
    }
    var autoRefresh: Bool {
        didSet { defaults.set(autoRefresh, forKey: Keys.autoRefresh) }
    }
    var refreshFrequency: Frequency {
        didSet { defaults.set(refreshFrequency.rawValue, forKey: Keys.frequency) }
    }
    private(set) var lastScheduledRun: Date? {
        didSet { defaults.set(lastScheduledRun, forKey: Keys.lastRun) }
    }

    private let store: WatchlistStore
    private let checker = WatchlistChecker()
    private let fetcher = WatchlistFetcher()
    private let monitor: DetectionMonitor
    private let defaults = UserDefaults.standard
    private var checkTask: Task<Void, Never>?
    private var started = false

    /// How often the schedule loop wakes to check whether work is due.
    private static let tickInterval: Duration = .seconds(15 * 60)

    private enum Keys {
        static let remoteURL = "watchlistRemoteURL"
        static let autoRefresh = "watchlistAutoRefresh"
        static let frequency = "watchlistRefreshFrequency"
        static let lastRun = "watchlistLastScheduledRun"
    }

    init(monitor: DetectionMonitor, store: WatchlistStore = WatchlistStore()) {
        self.monitor = monitor
        self.store = store
        self.remoteURL = defaults.string(forKey: Keys.remoteURL) ?? ""
        self.autoRefresh = defaults.bool(forKey: Keys.autoRefresh)
        self.refreshFrequency =
            Frequency(rawValue: defaults.string(forKey: Keys.frequency) ?? "") ?? .daily
        self.lastScheduledRun = defaults.object(forKey: Keys.lastRun) as? Date
        loadLocal()
    }

    // MARK: - Schedule loop

    /// Kicks off the schedule loop. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        Task {
            while !Task.isCancelled {
                await tick()
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    private func tick() async {
        guard autoRefresh, !isChecking, !entries.isEmpty || !remoteURL.isEmpty else { return }
        let due = lastScheduledRun.map {
            Date().timeIntervalSince($0) >= refreshFrequency.seconds
        } ?? true
        guard due else { return }
        lastScheduledRun = Date()
        if !remoteURL.isEmpty { await fetchRemote() }
        checkNow()
    }

    // MARK: - Persistence

    func loadLocal() {
        do {
            entries = try store.loadEntries()
            checkState = try store.loadState()
            storeError = nil
        } catch {
            storeError = error.localizedDescription
        }
    }

    private func saveEntries() {
        do {
            try store.saveEntries(entries)
            storeError = nil
        } catch {
            storeError = error.localizedDescription
        }
    }

    private func saveState() {
        do {
            try store.saveState(checkState, keeping: entries)
        } catch {
            storeError = error.localizedDescription
        }
    }

    // MARK: - Entry CRUD (local entries only)

    func addEntry(_ entry: WatchlistEntry) {
        entries.append(entry)
        saveEntries()
    }

    func updateEntry(_ entry: WatchlistEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        saveEntries()
    }

    func removeEntry(_ entry: WatchlistEntry) {
        entries.removeAll { $0.id == entry.id }
        checkState[entry.id] = nil
        saveEntries()
        saveState()
    }

    // MARK: - Remote refresh

    func fetchRemote() async {
        guard !isFetching else { return }
        let trimmed = remoteURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), !trimmed.isEmpty else {
            fetchError = "Enter a feed URL first."
            return
        }
        isFetching = true
        fetchError = nil
        do {
            let fetched = try await fetcher.fetch(from: url)
            entries = WatchlistStore.merge(remote: fetched, into: entries)
            saveEntries()
            // Merge never touches checkState: baselines for feed entries
            // that persist across fetches survive by construction.
            lastFetch = Date()
        } catch {
            fetchError = error.localizedDescription
        }
        isFetching = false
    }

    // MARK: - Checking

    func checkNow() {
        guard !isChecking, !entries.isEmpty else { return }
        isChecking = true
        checkError = nil
        checkProgress = (checked: 0, total: entries.count)
        monitor.setFileMonitorFindings([])

        let checker = self.checker
        let entries = self.entries
        let state = self.checkState
        checkTask = Task {
            var alerts: [Finding] = []
            for await event in checker.check(entries: entries, state: state) {
                switch event {
                case .checking:
                    break
                case .found(let finding, let entry):
                    if finding.isAlert {
                        alerts.append(Finding(
                            source: .fileMonitor,
                            date: Date(),
                            title: "\(entry.label): \(finding.reasons.joined(separator: ", "))",
                            detail: finding.path,
                            path: finding.exists ? finding.path : nil))
                        monitor.setFileMonitorFindings(alerts)
                    }
                case .completed(let entry, let newState):
                    checkState[entry.id] = newState
                    if let progress = checkProgress {
                        checkProgress = (progress.checked + 1, progress.total)
                    }
                case .failed(let entry, let error):
                    checkError = "\(entry.label): \(error)"
                case .finished:
                    break
                }
            }
            saveState()
            lastCheck = Date()
            checkProgress = nil
            isChecking = false
            checkTask = nil
        }
    }

    func stopCheck() {
        checkTask?.cancel()
    }

    // MARK: - Pane helpers

    func state(for entry: WatchlistEntry) -> WatchlistCheckState? {
        checkState[entry.id]
    }

    /// Findings across all entries, alerts first.
    var allFindings: [(entry: WatchlistEntry, finding: WatchlistFinding)] {
        entries.flatMap { entry in
            (checkState[entry.id]?.findings ?? []).map { (entry, $0) }
        }
        .sorted { lhs, rhs in
            if lhs.finding.isAlert != rhs.finding.isAlert { return lhs.finding.isAlert }
            return lhs.finding.path < rhs.finding.path
        }
    }

}
