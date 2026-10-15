import AppKit
import XCTest
@testable import Snapspool

@MainActor
final class FirstLaunchSetupTests: XCTestCase {
    func testGuideIsShownOnlyOnFirstLaunchAcrossControllerInstances() throws {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstLaunch = FirstLaunchSetupController(defaults: defaults)

        XCTAssertTrue(firstLaunch.showIfNeeded())
        XCTAssertTrue(try XCTUnwrap(firstLaunch.window).isVisible)
        firstLaunch.close()

        let secondLaunch = FirstLaunchSetupController(defaults: defaults)
        XCTAssertFalse(secondLaunch.showIfNeeded())
        XCTAssertFalse(try XCTUnwrap(secondLaunch.window).isVisible)
    }

    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "FirstLaunchSetupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    func testEnglishAndJapaneseGuideExplainRequiredSetupAndDestination() throws {
        let appBundle = try XCTUnwrap(Bundle(url: try builtAppURL()))
        let english = SetupGuideContent.localized(bundle: appBundle, language: "en")
        let japanese = SetupGuideContent.localized(bundle: appBundle, language: "ja")

        XCTAssertTrue(english.introduction.contains("copies screenshots to the clipboard"))
        XCTAssertTrue(english.shortcutInstructions.contains("Save picture of selected area as a file"))
        XCTAssertTrue(english.shortcutInstructions.contains("Copy picture of selected area to the clipboard"))
        XCTAssertTrue(english.destinationInstructions.contains("~/Pictures/Snapspool/"))
        XCTAssertTrue(english.destinationInstructions.contains("Settings"))

        XCTAssertTrue(japanese.introduction.contains("スクリーンショットをクリップボードにコピー"))
        XCTAssertTrue(japanese.shortcutInstructions.contains("ファイルとして保存"))
        XCTAssertTrue(japanese.shortcutInstructions.contains("クリップボードにコピー"))
        XCTAssertTrue(japanese.destinationInstructions.contains("~/Pictures/Snapspool/"))
        XCTAssertTrue(japanese.destinationInstructions.contains("設定画面"))
    }

    private func builtAppURL() throws -> URL {
        var directory = Bundle(for: Self.self).bundleURL
        for _ in 0..<8 {
            if directory.lastPathComponent == "Snapspool.app" {
                return directory
            }
            let sibling = directory.deletingLastPathComponent()
                .appendingPathComponent("Snapspool.app", isDirectory: true)
            if FileManager.default.fileExists(atPath: sibling.path) {
                return sibling
            }
            let parent = directory.deletingLastPathComponent()
            guard parent != directory else { break }
            directory = parent
        }
        return try XCTUnwrap(nil, "Could not locate the built Snapspool.app")
    }
}
