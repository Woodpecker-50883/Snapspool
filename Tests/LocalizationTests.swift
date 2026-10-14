import Foundation
import XCTest
@testable import Snapspool

final class LocalizationTests: XCTestCase {
    private let expectedTranslations: [String: (english: String, japanese: String)] = [
        "menu.history": ("History", "履歴"),
        "menu.pause-monitoring": ("Pause Monitoring", "監視の一時停止"),
        "menu.resume-monitoring": ("Resume Monitoring", "監視を再開"),
        "menu.settings": ("Settings", "設定"),
        "menu.quit": ("Quit", "終了"),
        "menu.shortcut-warning": ("⚠︎ Unable to Register Shortcut", "⚠︎ ショートカットを登録できません"),
        "history.empty": ("No History", "履歴がありません"),
        "settings.destination-folder": ("Destination Folder", "保存先フォルダ"),
        "settings.choose": ("Choose…", "選択…"),
        "settings.image-history-count": ("Image History: %lld", "画像の履歴件数: %lld"),
        "settings.text-history-count": ("Text History: %lld", "テキストの履歴件数: %lld"),
        "settings.shortcut": ("Shortcut", "ショートカット"),
        "settings.modifier-key": ("Modifier Key", "修飾キー"),
        "settings.key": ("Key", "キー"),
        "settings.shortcut-error-title": ("Unable to Change Shortcut", "ショートカットを変更できません"),
        "settings.shortcut-error-message": (
            "This shortcut cannot be registered. The previous setting will be used.",
            "このショートカットは登録できません。以前の設定を使用します。"
        ),
        "notification.destination-save-failed": (
            "The image could not be written to the destination, so it was saved in temporary history storage.",
            "画像を保存先へ書き込めなかったため、履歴用の退避領域に保存しました。"
        ),
        "notification.fallback-save-failed": (
            "The image could not be saved and was not added to history.",
            "画像を保存できなかったため、履歴には追加されませんでした。"
        ),
        "common.ok": ("OK", "OK"),
    ]

    func testBuiltApplicationContainsEnglishAndJapaneseLocalizations() throws {
        let appBundle = try XCTUnwrap(Bundle(url: try builtAppURL()))

        for (key, translations) in expectedTranslations {
            XCTAssertEqual(L10n.string(key, bundle: appBundle, language: "en"), translations.english)
            XCTAssertEqual(L10n.string(key, bundle: appBundle, language: "ja"), translations.japanese)
        }
    }

    func testSystemLanguagePreferencesSelectTheMatchingLocalization() throws {
        let appBundle = try XCTUnwrap(Bundle(url: try builtAppURL()))

        XCTAssertEqual(
            Bundle.preferredLocalizations(from: appBundle.localizations, forPreferences: ["en-US"]).first,
            "en"
        )
        XCTAssertEqual(
            Bundle.preferredLocalizations(from: appBundle.localizations, forPreferences: ["ja-JP"]).first,
            "ja"
        )
    }

    func testLocalizedCountFormatsResolveInBothLanguages() throws {
        let appBundle = try XCTUnwrap(Bundle(url: try builtAppURL()))
        let englishFormat = L10n.string("settings.image-history-count", bundle: appBundle, language: "en")
        let japaneseFormat = L10n.string("settings.image-history-count", bundle: appBundle, language: "ja")

        XCTAssertEqual(String(format: englishFormat, 30), "Image History: 30")
        XCTAssertEqual(String(format: japaneseFormat, 30), "画像の履歴件数: 30")
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
