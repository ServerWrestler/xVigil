import Foundation
import Observation
import xVigilCore

/// Observable state for the menu bar UI. Loads everything off the main actor
/// and publishes results back to it.
@MainActor
@Observable
final class VigilModel {
    private(set) var status: SystemStatus?
    private(set) var totalEventCount: Int = 0
    private(set) var lastRefreshed: Date?
    private(set) var errorMessage: String?
    private(set) var isRefreshing = false

    private let store = QuarantineStore()

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil

        let store = self.store
        Task {
            do {
                // Status blocks on spctl, so it loads via GCD; the SQLite
                // read is fast enough for a detached task.
                async let status = SystemStatus.load()
                let count = try await Task.detached(priority: .userInitiated) {
                    try store.eventCount()
                }.value
                self.status = await status
                self.totalEventCount = count
                self.lastRefreshed = Date()
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isRefreshing = false
        }
    }
}
