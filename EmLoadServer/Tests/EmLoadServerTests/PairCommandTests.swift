import Foundation
import SideSign
import XCTest
@testable import EmLoadServerKit

final class PairCommandTests: XCTestCase {
    func testParseRequiresValidUDIDAndOutputPath() throws {
        let command = try PairCommand.parse(arguments: [
            "--udid", "0123456789ABCDEF",
            "--output", "/tmp/pairing.plist"
        ])

        XCTAssertEqual(command.udid, "0123456789ABCDEF")
        XCTAssertEqual(command.outputURL.path, "/tmp/pairing.plist")
    }

    func testParseRejectsPathLikeUDID() {
        XCTAssertThrowsError(try PairCommand.parse(arguments: [
            "--udid", "../pairing",
            "--output", "/tmp/pairing.plist"
        ]))
    }

    func testParseAcceptsHyphenatedUDID() throws {
        let command = try PairCommand.parse(arguments: [
            "--udid", "00008110-000C4D8E0C40401E",
            "--output", "/tmp/pairing.plist"
        ])

        XCTAssertEqual(command.udid, "00008110-000C4D8E0C40401E")
    }

    func testRunPairsValidatesAndWritesPrivatePairingRecord() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let lockdown = root.appendingPathComponent("lockdown")
        let outputDirectory = root.appendingPathComponent("output")
        let toolDirectory = root.appendingPathComponent("bin")
        try fileManager.createDirectory(at: lockdown, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: toolDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let udid = "0123456789ABCDEF"
        let record = try PropertyListSerialization.data(
            fromPropertyList: ["HostID": "test-host"],
            format: .xml,
            options: 0
        )
        try record.write(to: lockdown.appendingPathComponent("\(udid).plist"))

        let toolURL = toolDirectory.appendingPathComponent("idevicepair")
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> "$EMLOADSERVER_TEST_CALLS"
        exit 0
        """.write(to: toolURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: toolURL.path)

        let callsURL = root.appendingPathComponent("calls.txt")
        let outputURL = outputDirectory.appendingPathComponent("pairing.plist")
        let command = try PairCommand.parse(arguments: [
            "--udid", udid,
            "--output", outputURL.path,
            "--record-dir", lockdown.path
        ])
        try command.run(
            executableURL: toolURL,
            environment: ["EMLOADSERVER_TEST_CALLS": callsURL.path]
        )

        XCTAssertEqual(try String(contentsOf: callsURL), "-u \(udid) pair\n-u \(udid) validate\n")
        XCTAssertEqual(try Data(contentsOf: outputURL), record)
        let attributes = try fileManager.attributesOfItem(atPath: outputURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRunDoesNotOverwriteExistingPairingFile() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let outputURL = root.appendingPathComponent("pairing.plist")
        try Data("keep".utf8).write(to: outputURL)
        let command = try PairCommand.parse(arguments: [
            "--udid", "0123456789ABCDEF",
            "--output", outputURL.path
        ])

        XCTAssertThrowsError(try command.run(executableURL: URL(fileURLWithPath: "/usr/bin/true")))
        XCTAssertEqual(try Data(contentsOf: outputURL), Data("keep".utf8))
    }
}

final class HostSignInTests: XCTestCase {
    func testLoginOptionsNeverAcceptPasswordArguments() throws {
        let options = try LoginOptions.parse(arguments: [
            "--apple-id", "account@example.com",
            "--server", "SideStore (New)"
        ])
        XCTAssertEqual(options.appleID, "account@example.com")
        XCTAssertEqual(options.server, "SideStore (New)")
        XCTAssertThrowsError(try LoginOptions.parse(arguments: ["--password", "secret"]))
    }

    func testRegistryKeepsOnlyUniqueHTTPSMacADIServers() throws {
        let data = Data(
            """
            {
              "servers": [
                {"name":"SideStore (New)","address":"https://new.ani.sidestore.io","kind":2},
                {"name":"Legacy","address":"https://legacy.example","kind":1},
                {"name":"Insecure","address":"http://unsafe.example","kind":2},
                {"name":"Duplicate","address":"https://new.ani.sidestore.io","kind":2}
              ]
            }
            """.utf8
        )

        let servers = try AnisetteServerRegistry.parse(data)
        XCTAssertEqual(servers.map(\.name), ["SideStore (New)"])
        XCTAssertEqual(
            try AnisetteServerRegistry.select(server: nil, from: servers).address,
            AnisetteServerRegistry.defaultAddress
        )
        XCTAssertEqual(
            try AnisetteServerRegistry.select(
                server: nil,
                preferredAddress: "https://new.ani.sidestore.io",
                from: servers
            ).name,
            "SideStore (New)"
        )
        XCTAssertThrowsError(
            try AnisetteServerRegistry.select(server: "Legacy", from: servers)
        )
    }
}

final class CompanionSideloadTests: XCTestCase {
    func testUDIDParserKeepsUSBIdentifiersAndDropsNoise() {
        let output = """
        00008110-001A2B3C4D5E6F7A
        ERROR: No device found
        0123456789ABCDEF0123456789ABCDEF01234567

        ../not-a-device
        """

        XCTAssertEqual(
            USBDeviceList.udids(from: output),
            [
                "00008110-001A2B3C4D5E6F7A",
                "0123456789ABCDEF0123456789ABCDEF01234567"
            ]
        )
        XCTAssertNil(USBDeviceList.infoValue(from: "ERROR: Could not connect\n"))
        XCTAssertEqual(USBDeviceList.infoValue(from: "Emily's iPhone\n"), "Emily's iPhone")
        XCTAssertEqual(USBDeviceList.deviceType(productType: "iPad14,1"), .iPad)
        XCTAssertEqual(USBDeviceList.deviceType(productType: "iPhone16,2"), .iPhone)
    }

    func testPreferredTeamUsesThePersonalTeam() {
        let teams = [
            Team(identifier: "ORGTEAM", name: "Example Org", type: .organization),
            Team(identifier: "FREETEAM", name: "Personal Team", type: .free)
        ]

        XCTAssertEqual(USBDeviceList.preferredTeam(in: teams)?.identifier, "FREETEAM")
        XCTAssertNil(USBDeviceList.preferredTeam(in: []))
    }

    func testLocatorUsesAnExistingCompanionBeforeBuilding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let app = root.appendingPathComponent("build/Release-iphoneos/EmLoadStoreCompanion.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = CompanionLocator(
            environment: [:],
            searchRoots: [root],
            buildProject: { _ in
                XCTFail("An existing companion should be used")
                return app
            }
        )

        XCTAssertEqual(try locator.locate().standardizedFileURL.path, app.standardizedFileURL.path)
    }

    func testLocatorBuildsWhenOnlyTheXcodeProjectIsPresent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = root.appendingPathComponent("EmLoadStore.xcodeproj", isDirectory: true)
        let built = root.appendingPathComponent("EmLoadStoreCompanion.app", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: built, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = CompanionLocator(
            environment: [:],
            searchRoots: [root],
            buildProject: { projectURL in
                XCTAssertEqual(projectURL.lastPathComponent, "EmLoadStore.xcodeproj")
                return built
            }
        )

        XCTAssertEqual(try locator.locate().path, built.path)
    }

    func testBundleIdentifierIsRewrittenBeforeSigning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let app = root.appendingPathComponent("EmLoadStoreCompanion.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let info = app.appendingPathComponent("Info.plist")
        let original = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.emiry.EmLoadStoreCompanion"],
            format: .xml,
            options: 0
        )
        try original.write(to: info)

        try CompanionLocator.alignBundleIdentifier(of: app, to: "com.example.EmLoadStoreCompanion")
        let data = try Data(contentsOf: info)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.example.EmLoadStoreCompanion")
    }

    func testCompanionIconReplacesTheCatalogIcon() throws {
        let source = try XCTUnwrap(CompanionIcon.bundledSource())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let app = root.appendingPathComponent("EmLoadStoreCompanion.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let info = app.appendingPathComponent("Info.plist")
        let original = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.emiry.EmLoadStoreCompanion",
                "CFBundleIcons": [
                    "CFBundlePrimaryIcon": [
                        "CFBundleIconFiles": ["AppIcon60x60"],
                        "CFBundleIconName": "AppIcon"
                    ]
                ]
            ],
            format: .xml,
            options: 0
        )
        try original.write(to: info)
        try Data("catalog".utf8).write(to: app.appendingPathComponent("Assets.car"))

        try CompanionIcon.apply(to: app, source: source)

        XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathComponent("Assets.car").path))
        for slot in CompanionIcon.slots {
            let icon = app.appendingPathComponent(slot.filename)
            XCTAssertTrue(FileManager.default.fileExists(atPath: icon.path), slot.filename)
        }
        let data = try Data(contentsOf: info)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        let icons = try XCTUnwrap(plist["CFBundleIcons"] as? [String: Any])
        let primary = try XCTUnwrap(icons["CFBundlePrimaryIcon"] as? [String: Any])
        XCTAssertNil(primary["CFBundleIconName"])
        XCTAssertEqual(primary["CFBundleIconFiles"] as? [String], ["AppIcon60x60"])
    }
}
