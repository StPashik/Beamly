import Foundation
import Sparkle
import XCTest

final class UpdateConfigurationTests: XCTestCase {
    func testAutomaticChecksRequireSignedHTTPSFeedAndExplicitInstallation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let url = try XCTUnwrap(URL(string: try XCTUnwrap(info["SUFeedURL"] as? String)))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.path, "/StPashik/Beamly/releases/latest/download/appcast.xml")
        let key = try XCTUnwrap(info["SUPublicEDKey"] as? String)
        XCTAssertEqual(Data(base64Encoded: key)?.count, 32)
        XCTAssertEqual(info["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertEqual(info["SURequireSignedFeed"] as? Bool, true)
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(info["SUAutomaticallyUpdate"] as? Bool, false)
        XCTAssertEqual(info["SUAllowsAutomaticUpdates"] as? Bool, false)
        XCTAssertEqual(info["SUSendProfileInfo"] as? Bool, false)
    }

    @MainActor
    func testSparklePersistsAutomaticCheckOptOutWithoutEnablingDownloadsOrProfiling() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-update-settings-\(UUID()).app")
        let contents = folder.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("Resources/Info.plist")), format: nil) as? [String: Any])
        let identifier = "app.beamly.update-settings-test.\(UUID().uuidString)"
        info["CFBundleIdentifier"] = identifier
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
        defer { defaults.removePersistentDomain(forName: identifier); try? FileManager.default.removeItem(at: folder) }
        let bundle = try XCTUnwrap(Bundle(url: folder))
        let settings = SPUUpdaterSettings(hostBundle: bundle)
        XCTAssertTrue(settings.automaticallyChecksForUpdates)
        XCTAssertFalse(settings.automaticallyDownloadsUpdates)
        XCTAssertFalse(settings.allowsAutomaticUpdates)
        XCTAssertFalse(settings.sendsSystemProfile)
        settings.automaticallyChecksForUpdates = false
        XCTAssertFalse(SPUUpdaterSettings(hostBundle: bundle).automaticallyChecksForUpdates, "Turning the checkbox off must survive relaunch")
        settings.automaticallyChecksForUpdates = true
        let restored = SPUUpdaterSettings(hostBundle: bundle)
        XCTAssertTrue(restored.automaticallyChecksForUpdates)
        XCTAssertFalse(restored.automaticallyDownloadsUpdates)
        XCTAssertFalse(restored.sendsSystemProfile)
    }
}
