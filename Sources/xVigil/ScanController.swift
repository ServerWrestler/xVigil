import Foundation
import Observation
import xVigilCore
import xVigilScan

/// Owns all scanning: engine availability, the persisted scan-path list,
/// live scan state, and the schedule loop. Lives at app scope (not the
/// dashboard) so scheduled scans run while the app sits in the menu bar.
@MainActor
@Observable
final class ScanController {
    enum Frequency: String, CaseIterable, Identifiable {
        case daily
        case weekly

        var id: String { rawValue }
        var label: String {
            switch self {
            case .daily: "Daily"
            case .weekly: "Weekly"
            }
        }
        var seconds: TimeInterval {
            switch self {
            case .daily: 86_400
            case .weekly: 7 * 86_400
            }
        }
    }

    private(set) var engineAvailability: EngineAvailability?
    private(set) var isScanning = false
    private(set) var threats: [Finding] = []
    private(set) var summary: ScanSummary?
    private(set) var statusLine: String?
    /// True when the most recent scan was started by the schedule.
    private(set) var lastRunWasScheduled = false

    var paths: [String] {
        didSet { defaults.set(paths, forKey: Keys.paths) }
    }
    var scheduleEnabled: Bool {
        didSet { defaults.set(scheduleEnabled, forKey: Keys.enabled) }
    }
    var frequency: Frequency {
        didSet { defaults.set(frequency.rawValue, forKey: Keys.frequency) }
    }
    private(set) var lastScheduledRun: Date? {
        didSet { defaults.set(lastScheduledRun, forKey: Keys.lastRun) }
    }

    private let engine = ClamAVEngine()
    private let monitor: DetectionMonitor
    private let defaults = UserDefaults.standard
    private var scanTask: Task<Void, Never>?
    private var started = false

    /// How often the schedule loop wakes to check whether a scan is due.
    private static let tickInterval: Duration = .seconds(15 * 60)

    private enum Keys {
        static let paths = "scanPaths"
        static let enabled = "scheduledScanEnabled"
        static let frequency = "scheduledScanFrequency"
        static let lastRun = "lastScheduledScanDate"
    }

    init(monitor: DetectionMonitor) {
        self.monitor = monitor
        self.paths = defaults.stringArray(forKey: Keys.paths) ?? Self.defaultPaths()
        self.scheduleEnabled = defaults.bool(forKey: Keys.enabled)
        self.frequency =
            Frequency(rawValue: defaults.string(forKey: Keys.frequency) ?? "") ?? .daily
        self.lastScheduledRun = defaults.object(forKey: Keys.lastRun) as? Date
    }

    static func defaultPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew", "/usr/local", home + "/Downloads"]
        return candidates.filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Kicks off the schedule loop. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        Task {
            while !Task.isCancelled {
                tick()
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    private func tick() {
        guard scheduleEnabled, !isScanning, !paths.isEmpty else { return }
        let due = lastScheduledRun.map {
            Date().timeIntervalSince($0) >= frequency.seconds
        } ?? true
        guard due else { return }
        lastScheduledRun = Date()
        lastRunWasScheduled = true
        scanTask = Task { await runScan() }
    }

    func checkEngine() {
        let engine = self.engine
        Task { self.engineAvailability = await engine.availability() }
    }

    func startManualScan() {
        guard !isScanning else { return }
        lastRunWasScheduled = false
        scanTask = Task { await runScan() }
    }

    func stopScan() {
        scanTask?.cancel()
    }

    func addPath(_ url: URL) {
        if !paths.contains(url.path) { paths.append(url.path) }
    }

    func removePath(_ path: String) {
        paths.removeAll { $0 == path }
    }

    private func runScan() async {
        guard !isScanning, !paths.isEmpty else { return }
        isScanning = true
        threats = []
        summary = nil
        statusLine = nil
        monitor.setScanFindings([])

        let urls = paths.map { URL(fileURLWithPath: $0) }
        for await event in engine.scan(paths: urls) {
            switch event {
            case .started(let scanner, _):
                statusLine = "Scanning with \(scanner)…"
            case .threatFound(let path, let signature):
                let finding = Finding(
                    source: .scan, date: Date(),
                    title: signature, detail: path, path: path)
                threats.append(finding)
                monitor.setScanFindings(threats)
            case .progress(let message):
                statusLine = message
            case .finished(let finished):
                summary = finished
                statusLine = nil
            }
        }
        isScanning = false
        scanTask = nil
    }
}
