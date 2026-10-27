import Foundation
import XCTest

final class UpdateConfigurationTests: XCTestCase {
    func testUpdatesRequireSignedHTTPSFeedAndExplicitUserAction() throws {
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
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, false)
        XCTAssertEqual(info["SUAutomaticallyUpdate"] as? Bool, false)
        XCTAssertEqual(info["SUAllowsAutomaticUpdates"] as? Bool, false)
        XCTAssertEqual(info["SUEnableSystemProfiling"] as? Bool, false)
    }
}
