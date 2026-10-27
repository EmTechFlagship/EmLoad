import XCTest
@testable import EmLoadMac

final class AppUpdateTests: XCTestCase {
    func testVersionOrder() {
        let versions = [
            "0.1.0-alpha2",
            "0.1.0-beta1",
            "0.1.0-beta2",
            "0.1.0-beta10",
            "0.1.0-rc1",
            "0.1.0",
            "0.2.0-beta1",
            "v0.2.0",
        ].map { ReleaseVersion.parse($0)! }

        for pair in zip(versions, versions.dropFirst()) {
            XCTAssertLessThan(pair.0, pair.1)
        }
        XCTAssertEqual(ReleaseVersion.parse("v0.1.0-beta1"), ReleaseVersion.parse("0.1.0-beta1"))
        XCTAssertNil(ReleaseVersion.parse("beta"))
    }

    func testCurrentPrefersStampedRelease() {
        let info: [String: Any] = [
            "EmLoadRelease": "0.1.0-beta2",
            "CFBundleShortVersionString": "0.1.0",
        ]
        XCTAssertEqual(ReleaseVersion.current(info: info).description, "0.1.0-beta2")
    }

    func testSelectsNewerPrereleaseAndSkipsWindowsArchive() throws {
        let releases = try AppUpdateChecker.parseReleases(fixture.data(using: .utf8)!)
        let current = ReleaseVersion.parse("0.1.0-beta1")!
        let update = AppUpdateChecker.select(releases: releases, current: current, architecture: "arm64")
        XCTAssertEqual(update?.version.description, "0.2.0-beta1")
        XCTAssertEqual(update?.assetName, "EmLoad-0.2.0-beta1-macos-arm64.zip")
        XCTAssertTrue(update?.prerelease == true)
    }

    func testUsesUniversalArchiveWhenCpuArchiveIsMissing() throws {
        let releases = try AppUpdateChecker.parseReleases(fixture.data(using: .utf8)!)
        let current = ReleaseVersion.parse("0.0.1")!
        let update = AppUpdateChecker.select(releases: releases, current: current, architecture: "x86_64")
        XCTAssertEqual(update?.assetName, "EmLoad-0.2.0-beta1-macos.zip")
    }

    func testLegacyWrapperWhenItIsTheOnlyMacArchive() throws {
        let json = """
        [{
          "tag_name": "v0.1.0-beta1",
          "name": "EmLoad 0.1.0 Beta 1",
          "prerelease": true,
          "draft": false,
          "html_url": "https://github.com/EmTechFlagship/EmLoadServer/releases/tag/v0.1.0-beta1",
          "body": "First beta",
          "assets": [
            {"name": "EmLoad-0.1.0-beta1-win-x64.zip", "browser_download_url": "https://github.com/EmTechFlagship/EmLoad/releases/download/v0.1.0-beta1/EmLoad-0.1.0-beta1-win-x64.zip"},
            {"name": "emload-macos-0.1.0-beta1.zip", "browser_download_url": "https://github.com/EmTechFlagship/EmLoad/releases/download/v0.1.0-beta1/emload-macos-0.1.0-beta1.zip"}
          ]
        }]
        """
        let releases = try AppUpdateChecker.parseReleases(json.data(using: .utf8)!)
        let update = AppUpdateChecker.select(
            releases: releases,
            current: ReleaseVersion.parse("0.1.0-beta0")!,
            architecture: "arm64"
        )
        XCTAssertEqual(update?.assetName, "emload-macos-0.1.0-beta1.zip")
    }

    func testIgnoresDraftsAndUntrustedLinks() throws {
        let json = """
        [{
          "tag_name": "v9.0.0-beta1",
          "name": "Draft",
          "prerelease": true,
          "draft": true,
          "html_url": "https://github.com/EmTechFlagship/EmLoadServer/releases/tag/v9.0.0-beta1",
          "assets": [{"name": "EmLoad-9.0.0-beta1-macos.zip", "browser_download_url": "https://github.com/EmTechFlagship/EmLoadServer/releases/download/v9.0.0-beta1/EmLoad-9.0.0-beta1-macos.zip"}]
        }, {
          "tag_name": "v8.0.0-beta1",
          "name": "Elsewhere",
          "prerelease": true,
          "draft": false,
          "html_url": "https://example.com/releases/tag/v8.0.0-beta1",
          "assets": [{"name": "EmLoad-8.0.0-beta1-macos.zip", "browser_download_url": "https://example.com/EmLoad-8.0.0-beta1-macos.zip"}]
        }]
        """
        let releases = try AppUpdateChecker.parseReleases(json.data(using: .utf8)!)
        XCTAssertNil(AppUpdateChecker.select(
            releases: releases,
            current: ReleaseVersion.parse("0.1.0")!,
            architecture: "arm64"
        ))
    }

    private let fixture = """
    [
      {
        "tag_name": "v0.1.0-beta2",
        "name": "Old",
        "prerelease": true,
        "draft": false,
        "html_url": "https://github.com/EmTechFlagship/EmLoadServer/releases/tag/v0.1.0-beta2",
        "body": "older",
        "assets": [
          {"name": "emload-macos-0.1.0-beta2.zip", "browser_download_url": "https://github.com/EmTechFlagship/EmLoad/releases/download/v0.1.0-beta2/emload-macos-0.1.0-beta2.zip"}
        ]
      },
      {
        "tag_name": "v0.2.0-beta1",
        "name": "EmLoad 0.2.0 Beta 1",
        "prerelease": true,
        "draft": false,
        "html_url": "https://github.com/EmTechFlagship/EmLoadServer/releases/tag/v0.2.0-beta1",
        "body": "notes",
        "assets": [
          {"name": "EmLoad-0.2.0-beta1-win-x64.zip", "browser_download_url": "https://github.com/EmTechFlagship/EmLoadServer/releases/download/v0.2.0-beta1/EmLoad-0.2.0-beta1-win-x64.zip"},
          {"name": "EmLoad-0.2.0-beta1-macos.zip", "browser_download_url": "https://github.com/EmTechFlagship/EmLoadServer/releases/download/v0.2.0-beta1/EmLoad-0.2.0-beta1-macos.zip"},
          {"name": "EmLoad-0.2.0-beta1-macos-arm64.zip", "browser_download_url": "https://github.com/EmTechFlagship/EmLoadServer/releases/download/v0.2.0-beta1/EmLoad-0.2.0-beta1-macos-arm64.zip"}
        ]
      }
    ]
    """
}
