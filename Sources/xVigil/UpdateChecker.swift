import Foundation
import Observation
import xVigilCore

/// Periodically asks GitHub whether a newer release exists, at a
/// user-chosen cadence. Notify-and-link only: xVigil never downloads or
/// installs updates itself — consistent with the report-only ethos.
@MainActor
@Observable
final class UpdateChecker {
    enum Frequency: String, CaseIterable, Identifiable {
        case daily
        case weekly
        case monthly

        var id: String { rawValue }
        var label: String {
            switch self {
            case .daily: "Daily"
            case .weekly: "Weekly"
            case .monthly: "Monthly"
            }
        }
        var seconds: TimeInterval {
            switch self {
            case .daily: 86_400
            case .weekly: 7 * 86_400
            case .monthly: 30 * 86_400
            }
        }
    }

    var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled) }
    }
    var frequency: Frequency {
        didSet { defaults.set(frequency.rawValue, forKey: Keys.frequency) }
    }
    /// Set when a newer release exists; drives the popover banner.
    private(set) var available: UpdateCheck.Release?
    private(set) var lastChecked: Date? {
        didSet { defaults.set(lastChecked, forKey: Keys.lastChecked) }
    }
    private(set) var isChecking = false
    private(set) var statusMessage: String?

    static let releaseAPI = URL(
        string: "https://api.github.com/repos/ServerWrestler/xVigil/releases/latest")!

    /// The loop wakes far more often than any frequency so a due check never
    /// waits long; the frequency gates the actual network request.
    private static let tickInterval: Duration = .seconds(6 * 3600)

    private let defaults = UserDefaults.standard
    private var started = false

    private enum Keys {
        static let enabled = "updateCheckEnabled"
        static let frequency = "updateCheckFrequency"
        static let lastChecked = "updateCheckLastDate"
    }

    init() {
        self.enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        self.frequency =
            Frequency(rawValue: defaults.string(forKey: Keys.frequency) ?? "") ?? .weekly
        self.lastChecked = defaults.object(forKey: Keys.lastChecked) as? Date
    }

    var currentVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// Kicks off the periodic loop. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        Task {
            while !Task.isCancelled {
                if enabled, currentVersion != nil {
                    // lastChecked only advances on success, so failures
                    // retry at the next tick rather than next period.
                    let due = lastChecked.map {
                        Date().timeIntervalSince($0) >= frequency.seconds
                    } ?? true
                    if due { await check() }
                }
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    func checkNow() {
        Task { await check() }
    }

    private func check() async {
        guard !isChecking else { return }
        guard let currentVersion else {
            statusMessage = "Update check needs the installed app "
                + "(no bundle version under swift run)."
            return
        }
        isChecking = true
        statusMessage = nil
        defer { isChecking = false }

        var request = URLRequest(url: Self.releaseAPI)
        request.setValue("xVigil-update-check", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                let release = UpdateCheck.parseLatestRelease(data)
            else {
                statusMessage = "Update check failed (unexpected response)."
                return
            }
            lastChecked = Date()
            if UpdateCheck.isVersion(release.version, newerThan: currentVersion) {
                available = release
            } else {
                available = nil
                statusMessage = "Up to date (\(currentVersion))."
            }
        } catch {
            statusMessage = "Update check failed: \(error.localizedDescription)"
        }
    }
}
