import Foundation

/// Snapshot of the Mac's built-in protection status.
public struct SystemStatus: Sendable {
    public let gatekeeperEnabled: Bool?
    /// XProtect signature definitions version (e.g. "5347").
    public let xprotectVersion: String?
    /// XProtect Remediator app version, if installed.
    public let remediatorVersion: String?

    public static func current() -> SystemStatus {
        SystemStatus(
            gatekeeperEnabled: readGatekeeperStatus(),
            xprotectVersion: bundleVersion(
                at: "/Library/Apple/System/Library/CoreServices/XProtect.bundle"),
            remediatorVersion: bundleVersion(
                at: "/Library/Apple/System/Library/CoreServices/XProtect.app")
        )
    }

    private static func bundleVersion(at path: String) -> String? {
        let plistURL = URL(fileURLWithPath: path)
            .appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let info = plist as? [String: Any]
        else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    private static func readGatekeeperStatus() -> Bool? {
        guard let result = try? Subprocess.run("/usr/sbin/spctl", arguments: ["--status"], timeout: 10) else {
            return nil
        }
        let output = result.stdoutText
        if output.contains("assessments enabled") { return true }
        if output.contains("assessments disabled") { return false }
        return nil
    }
}
