import Foundation

/// Pure logic for the in-app update check: parsing GitHub's latest-release
/// response and comparing versions. Networking and scheduling live in the
/// app layer.
public enum UpdateCheck {
    public struct Release: Equatable, Sendable {
        /// Version with any leading "v" stripped (e.g. "1.1.0").
        public let version: String
        /// The release's web page, for the user to open.
        public let url: URL

        public init(version: String, url: URL) {
            self.version = version
            self.url = url
        }
    }

    /// Parses the response of `GET /repos/<owner>/<repo>/releases/latest`.
    /// That endpoint already excludes drafts and pre-releases; the guards are
    /// belt-and-braces.
    public static func parseLatestRelease(_ data: Data) -> Release? {
        struct Response: Decodable {
            let tag_name: String
            let html_url: String
            let draft: Bool
            let prerelease: Bool
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
            !response.draft, !response.prerelease,
            let url = URL(string: response.html_url)
        else { return nil }
        return Release(version: normalize(response.tag_name), url: url)
    }

    /// "v1.2.0" → "1.2.0"
    public static func normalize(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Numeric component-wise comparison. Missing components count as zero
    /// ("1.1" == "1.1.0"); non-numeric suffixes are ignored ("2-beta" → 2).
    public static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let lhs = components(normalize(candidate))
        let rhs = components(normalize(current))
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }
}
