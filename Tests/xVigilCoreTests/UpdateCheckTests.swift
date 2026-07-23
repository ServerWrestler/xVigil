import Foundation
import Testing
@testable import xVigilCore

@Suite struct UpdateCheckTests {
    @Test func parsesLatestReleaseResponse() throws {
        let json = """
            {"tag_name": "v1.2.0",
             "html_url": "https://github.com/ServerWrestler/xVigil/releases/tag/v1.2.0",
             "draft": false, "prerelease": false,
             "name": "xVigil 1.2.0", "assets": []}
            """
        let release = try #require(UpdateCheck.parseLatestRelease(Data(json.utf8)))
        #expect(release.version == "1.2.0")
        #expect(release.url.absoluteString.hasSuffix("/tag/v1.2.0"))
    }

    @Test func rejectsPrereleasesAndGarbage() {
        let prerelease = """
            {"tag_name": "v2.0.0-beta", "html_url": "https://example.com",
             "draft": false, "prerelease": true}
            """
        #expect(UpdateCheck.parseLatestRelease(Data(prerelease.utf8)) == nil)
        #expect(UpdateCheck.parseLatestRelease(Data("not json".utf8)) == nil)
        #expect(UpdateCheck.parseLatestRelease(Data("{}".utf8)) == nil)
    }

    @Test func comparesVersionsNumerically() {
        #expect(UpdateCheck.isVersion("1.2.0", newerThan: "1.1.0"))
        #expect(UpdateCheck.isVersion("v1.2.0", newerThan: "1.1.9"))
        // Numeric, not lexicographic: 1.10 > 1.9.
        #expect(UpdateCheck.isVersion("1.10.0", newerThan: "1.9.9"))
        #expect(UpdateCheck.isVersion("2.0", newerThan: "1.99.99"))
        #expect(!UpdateCheck.isVersion("1.1.0", newerThan: "1.1.0"))
        // Missing components count as zero.
        #expect(!UpdateCheck.isVersion("1.1", newerThan: "1.1.0"))
        #expect(!UpdateCheck.isVersion("1.0.9", newerThan: "1.1.0"))
    }

    @Test func normalizesTags() {
        #expect(UpdateCheck.normalize("v1.1.0") == "1.1.0")
        #expect(UpdateCheck.normalize("1.1.0") == "1.1.0")
    }
}
