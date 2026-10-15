import AppKit
import SwiftUI
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
        XCTAssertEqual(english.openSettingsButtonTitle, "Open Keyboard Shortcuts…")
        XCTAssertTrue(english.manualSettingsPath.contains("System Settings > Keyboard > Keyboard Shortcuts > Screenshots"))

        XCTAssertTrue(japanese.introduction.contains("スクリーンショットをクリップボードにコピー"))
        XCTAssertTrue(japanese.shortcutInstructions.contains("ファイルとして保存"))
        XCTAssertTrue(japanese.shortcutInstructions.contains("クリップボードにコピー"))
        XCTAssertTrue(japanese.destinationInstructions.contains("~/Pictures/Snapspool/"))
        XCTAssertTrue(japanese.destinationInstructions.contains("設定画面"))
        XCTAssertEqual(japanese.openSettingsButtonTitle, "キーボードショートカットを開く…")
        XCTAssertTrue(japanese.manualSettingsPath.contains("システム設定 > キーボード > キーボードショートカット > スクリーンショット"))
    }

    func testSystemSettingsOpenerUsesKeyboardShortcutsDeepLinkAndReportsResult() {
        var openedURLs: [URL] = []
        let successfulOpener = SystemKeyboardShortcutSettingsOpener { url in
            openedURLs.append(url)
            return true
        }

        XCTAssertTrue(successfulOpener.open())
        XCTAssertEqual(openedURLs, [SystemKeyboardShortcutSettingsOpener.settingsURL])
        XCTAssertEqual(
            openedURLs.first?.absoluteString,
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts"
        )

        let failingOpener = SystemKeyboardShortcutSettingsOpener { _ in false }
        XCTAssertFalse(failingOpener.open())
    }

    func testSetupControllerButtonActionUsesSystemSettingsOpener() {
        var openedURL: URL?
        let opener = SystemKeyboardShortcutSettingsOpener { url in
            openedURL = url
            return true
        }
        let controller = FirstLaunchSetupController(settingsOpener: opener)
        let hostingController = controller.window?.contentViewController
            as? NSHostingController<FirstLaunchSetupView>

        hostingController?.rootView.openSettings()
        XCTAssertEqual(openedURL, SystemKeyboardShortcutSettingsOpener.settingsURL)
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
