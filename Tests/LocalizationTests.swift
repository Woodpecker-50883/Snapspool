import Foundation
import XCTest
@testable import Snapspool

final class LocalizationTests: XCTestCase {
    private let expectedTranslations: [String: (english: String, japanese: String)] = [
        "menu.history": ("History", "履歴"),
        "menu.pause-monitoring": ("Pause Monitoring", "監視の一時停止"),
        "menu.resume-monitoring": ("Resume Monitoring", "監視を再開"),
        "menu.settings": ("Settings", "設定"),
        "menu.setup-guide": ("Screenshot Setup Guide…", "スクリーンショットの設定…"),
        "menu.privacy-policy": ("Privacy Policy", "プライバシーポリシー"),
        "menu.quit": ("Quit", "終了"),
        "menu.shortcut-warning": ("⚠︎ Unable to Register Shortcut", "⚠︎ ショートカットを登録できません"),
        "history.empty": ("No History", "履歴がありません"),
        "history.count-summary": ("Images: %lld  Text: %lld", "画像: %lld件  テキスト: %lld件"),
        "history.controls-hint": (
            "↑↓ Move  •  Return Select  •  Esc Close",
            "↑↓ 選択を移動  •  Return 確定  •  Esc 閉じる"
        ),
        "history.restore-failed": (
            "This item could not be restored. Its saved file may be missing or damaged.",
            "この項目を復元できませんでした。保存済みファイルが消失または破損している可能性があります。"
        ),
        "settings.destination-folder": ("Destination Folder", "保存先フォルダ"),
        "settings.choose": ("Choose…", "選択…"),
        "settings.image-history-count": ("Image History: %lld", "画像の履歴件数: %lld"),
        "settings.text-history-count": ("Text History: %lld", "テキストの履歴件数: %lld"),
        "settings.shortcut": ("Shortcut", "ショートカット"),
        "settings.auto-paste": (
            "Paste automatically after selecting history",
            "履歴の選択後に自動で貼り付ける"
        ),
        "settings.shortcut-recording": ("Type Shortcut", "ショートカットを入力"),
        "settings.shortcut-error-title": ("Unable to Change Shortcut", "ショートカットを変更できません"),
        "settings.shortcut-error-message": (
            "This shortcut cannot be registered. The previous setting will be used.",
            "このショートカットは登録できません。以前の設定を使用します。"
        ),
        "settings.shortcut-modifier-required": (
            "A shortcut must include at least one modifier key.",
            "ショートカットには修飾キーが1つ以上必要です。"
        ),
        "settings.shortcut-shift-option-unsupported": (
            "On this version of macOS, Shift and Option alone cannot be used for a global shortcut. Add Control or Command.",
            "このバージョンのmacOSでは、ShiftとOptionだけのグローバルショートカットは使用できません。ControlまたはCommandを追加してください。"
        ),
        "setup.title": ("Set Up Screenshots", "スクリーンショットの設定"),
        "setup.introduction": (
            "To use screenshots with Snapspool, enable a macOS screenshot shortcut that copies screenshots to the clipboard.",
            "スクリーンショットをSnapspoolで扱うには、macOSの「スクリーンショットをクリップボードにコピー」のショートカットを有効にしてください。"
        ),
        "setup.shortcut-instructions": (
            "You can move the key combination you already use from “Save picture of selected area as a file” to “Copy picture of selected area to the clipboard” and keep taking screenshots with the same keys.",
            "「ファイルとして保存」側に使っていたキーを「クリップボードにコピー」側へ付け替えると、普段と同じキーのままスクリーンショットを撮れます。"
        ),
        "setup.destination-instructions": (
            "Images are saved to ~/Pictures/Snapspool/ by default. You can choose a different folder in Settings.",
            "画像の既定の保存先は ~/Pictures/Snapspool/ です。設定画面から別のフォルダへ変更できます。"
        ),
        "setup.manual-settings-path": (
            "If System Settings does not open, go to System Settings > Keyboard > Keyboard Shortcuts > Screenshots.",
            "システム設定が開かない場合は、システム設定 > キーボード > キーボードショートカット > スクリーンショット の順に開いてください。"
        ),
        "setup.open-settings": ("Open Keyboard Shortcuts…", "キーボードショートカットを開く…"),
        "setup.done": ("Done", "完了"),
        "notification.destination-save-failed": (
            "The image could not be written to the destination, so it was saved in temporary history storage.",
            "画像を保存先へ書き込めなかったため、履歴用の退避領域に保存しました。"
        ),
        "notification.fallback-save-failed": (
            "The image could not be saved and was not added to history.",
            "画像を保存できなかったため、履歴には追加されませんでした。"
        ),
        "autopaste.permission-required-title": (
            "Automatic Paste Unavailable",
            "自動貼り付けを利用できません"
        ),
        "autopaste.permission-required-message": (
            "The item was restored to the clipboard. Press Cmd+V to paste it.\n\nTo allow automatic paste, go to System Settings > Privacy & Security > Accessibility and enable Snapspool. You may need to restart Snapspool after granting access.",
            "クリップボードに戻したので Cmd+V で貼り付けてください。\n\n自動貼り付けを許可するには、システム設定 > プライバシーとセキュリティ > アクセシビリティ の順に開き、Snapspoolを有効にしてください。許可後にSnapspoolの再起動が必要な場合があります。"
        ),
        "autopaste.open-accessibility-settings": (
            "Open Accessibility Settings…",
            "アクセシビリティ設定を開く…"
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

        let englishHistoryFormat = L10n.string("history.count-summary", bundle: appBundle, language: "en")
        let japaneseHistoryFormat = L10n.string("history.count-summary", bundle: appBundle, language: "ja")
        XCTAssertEqual(String(format: englishHistoryFormat, 2, 1), "Images: 2  Text: 1")
        XCTAssertEqual(String(format: japaneseHistoryFormat, 2, 1), "画像: 2件  テキスト: 1件")
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
