import Foundation
import Observation
import xVigilCore

/// Observable state for the menu bar UI. Loads everything off the main actor
/// and publishes results back to it.
@MainActor
@Observable
final class VigilModel {
    private(set) var status: SystemStatus?
    private(set) var recentEvents: [QuarantineEvent] = []
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
                let loaded = try await Task.detached(priority: .userInitiated) {
                    let status = SystemStatus.current()
                    let events = try store.recentEvents(limit: 20)
                    let count = try store.eventCount()
                    return (status, events, count)
                }.value
                self.status = loaded.0
                self.recentEvents = loaded.1
                self.totalEventCount = loaded.2
                self.lastRefreshed = Date()
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isRefreshing = false
        }
    }
}
