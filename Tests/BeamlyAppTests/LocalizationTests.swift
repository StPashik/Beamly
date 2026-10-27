import Foundation
import XCTest
@testable import Beamly

final class LocalizationTests: XCTestCase {
    func testLanguageOverridesSystemPreferenceAndPersistsAcrossLaunches() throws {
        let name = "Beamly-language-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["ru"], forKey: "AppleLanguages")
        XCTAssertEqual(AppLanguage.configureAtLaunch(defaults: defaults), .en)
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"])

        defaults.set("es", forKey: "appLanguage")
        XCTAssertEqual(AppLanguage.configureAtLaunch(defaults: defaults), .es)
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["es"])
        XCTAssertEqual(AppLanguage.configureAtLaunch(defaults: defaults), .es)

        defaults.set("invalid", forKey: "appLanguage")
        XCTAssertEqual(AppLanguage.configureAtLaunch(defaults: defaults), .en)
    }

    func testCatalogsHaveFiveCompleteTranslationsWithMatchingFormatArguments() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let format = try NSRegularExpression(pattern: "%[@d]")
        func placeholders(_ value: String) -> [String] {
            format.matches(in: value, range: NSRange(value.startIndex..., in: value)).map { (value as NSString).substring(with: $0.range) }
        }
        for name in ["Localizable", "InfoPlist"] {
            let data = try Data(contentsOf: root.appendingPathComponent("Resources/\(name).xcstrings"))
            let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(catalog["sourceLanguage"] as? String, "en")
            let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
            XCTAssertFalse(strings.isEmpty)
            for (key, entry) in strings {
                let localizations = try XCTUnwrap(entry["localizations"] as? [String: [String: Any]], key)
                XCTAssertEqual(Set(localizations.keys), Set(AppLanguage.allCases.map(\.rawValue)), key)
                for (language, localization) in localizations {
                    let unit = try XCTUnwrap(localization["stringUnit"] as? [String: String], "\(key): \(language)")
                    let value = try XCTUnwrap(unit["value"])
                    XCTAssertFalse(value.isEmpty, "\(key): \(language)")
                    XCTAssertEqual(unit["state"], "translated")
                    XCTAssertEqual(placeholders(value), placeholders(key), "\(key): \(language)")
                }
            }
        }
    }
}
