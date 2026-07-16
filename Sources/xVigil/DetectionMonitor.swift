import Foundation
import Observation
import xVigilCore

/// The app-wide findings surface. XProtect log detections (from periodic
/// background sweeps) and on-demand scan hits both land here; the menu bar
/// icon, popover banner, and Detections dashboard section all read from it.
@MainActor
@Observable
final class DetectionMonitor {
    private(set) var xprotectFindings: [Finding] = []
    private(set) var scanFindings: [Finding] = []
    private(set) var lastSweep: Date?
    private(set) var isSweeping = false

    /// Newest first, both sources merged.
    var findings: [Finding] {
        (scanFindings + xprotectFindings).sorted {
            ($0.date ?? .distantPast) > ($1.date ?? .distantPast)
        }
    }

    var count: Int { xprotectFindings.count + scanFindings.count }

    private var started = false
    private static let sweepWindow = "24h"
    private static let sweepInterval: Duration = .seconds(30 * 60)

    /// Kicks off the periodic background log sweep. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        Task {
            while !Task.isCancelled {
                await sweep()
                try? await Task.sleep(for: Self.sweepInterval)
            }
        }
    }

    func sweep() async {
        guard !isSweeping else { return }
        isSweeping = true
        defer { isSweeping = false }

        let reader = XProtectLogReader()
        guard let entries = try? await reader.entries(last: Self.sweepWindow) else { return }
        xprotectFindings = entries
            .filter { $0.kind == .detection }
            .map(Finding.init(detection:))
        lastSweep = Date()
    }

    /// Replaces the scan-sourced findings (called as an on-demand scan
    /// streams results; each new scan starts from its own empty list).
    func setScanFindings(_ findings: [Finding]) {
        scanFindings = findings
    }
}
