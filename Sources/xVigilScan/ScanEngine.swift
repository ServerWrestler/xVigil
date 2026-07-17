import Foundation

/// A pluggable on-demand scanner backend. xVigil detects engines the user
/// has installed rather than bundling one; the UI stays engine-agnostic.
public protocol ScanEngine: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// Installed? Daemon up? Signature database age? Cheap enough to call
    /// on every pane appearance.
    func availability() async -> EngineAvailability
    /// Streams results live. Report-only by contract: engines must never
    /// quarantine, delete, or modify what they find.
    func scan(paths: [URL]) -> AsyncStream<ScanEvent>
}

public struct EngineAvailability: Equatable, Sendable {
    /// Some usable scanner binary exists.
    public let installed: Bool
    /// Fast daemon-backed scanning available (e.g. clamdscan with clamd up).
    public let daemonRunning: Bool
    /// The binary a scan would use right now.
    public let scannerPath: String?
    /// Age of the newest signature database file, if determinable.
    public let signatureAge: TimeInterval?
    /// Human-readable diagnostics ("clamdscan at /opt/homebrew/bin, daemon up").
    public let detail: String

    public init(
        installed: Bool,
        daemonRunning: Bool,
        scannerPath: String?,
        signatureAge: TimeInterval?,
        detail: String
    ) {
        self.installed = installed
        self.daemonRunning = daemonRunning
        self.scannerPath = scannerPath
        self.signatureAge = signatureAge
        self.detail = detail
    }

    /// Definitions older than this deserve a warning: stale signatures give
    /// false confidence, which is exactly what this app exists to combat.
    public static let staleSignatureThreshold: TimeInterval = 7 * 24 * 3600

    public var signaturesStale: Bool {
        guard let signatureAge else { return true }
        return signatureAge > Self.staleSignatureThreshold
    }
}

public enum ScanEvent: Sendable {
    case started(scanner: String, paths: [String])
    case threatFound(path: String, signature: String)
    /// Non-threat output worth relaying (warnings, skipped files).
    case progress(message: String)
    case finished(ScanSummary)
}

public struct ScanSummary: Equatable, Sendable {
    public let infectedCount: Int
    public let scannedCount: Int?
    public let duration: TimeInterval
    public let exitStatus: Int32
    /// Set when the scan failed outright (engine missing, exit status 2).
    public let errorMessage: String?

    public init(
        infectedCount: Int,
        scannedCount: Int?,
        duration: TimeInterval,
        exitStatus: Int32,
        errorMessage: String?
    ) {
        self.infectedCount = infectedCount
        self.scannedCount = scannedCount
        self.duration = duration
        self.exitStatus = exitStatus
        self.errorMessage = errorMessage
    }
}
