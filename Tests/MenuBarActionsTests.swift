import AppKit
import Carbon.HIToolbox
import Combine
import XCTest
@testable import Snapspool

@MainActor
final class MenuBarActionsTests: XCTestCase {
    // テスト中だけステータス項目を生かしておく。
    // 保持し続けるとメニューバーの枠が埋まり、後のテストの項目が画面外に置かれる
    private static var retainedStatusItemControllers: [MenuBarStatusItemController] = []
    private static var retainedRuntimes: [SnapspoolRuntime] = []

    override func tearDown() {
        Self.retainedStatusItemControllers.removeAll()
        Self.retainedRuntimes.removeAll()
        super.tearDown()
    }

    func testStatusItemControllerConfiguresButtonAndRequiredMenu() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
            "テストバンドルを直接実行した場合はステータス項目を生成できないためスキップ（xcodebuild test でのみ実行される）"
        )
        let menu = MenuBarActions(
            clipboardMonitor: ClipboardMonitor(pasteboard: FakeMenuPasteboard()) { _ in }
        ).makeMenu()

        let controller = MenuBarStatusItemController(menu: menu)
        let button = try XCTUnwrap(controller.statusItem.button)

        let image = try XCTUnwrap(button.image)
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.accessibilityDescription, "Snapspool")
        XCTAssertEqual(button.title, "")
        XCTAssertEqual(button.toolTip, "Snapspool")
        XCTAssertTrue(controller.statusItem.menu === menu)
        XCTAssertEqual(menu.items.map(\.title), [
            L10n.string("menu.history"),
            L10n.string("menu.pause-monitoring"),
            L10n.string("menu.settings"),
            L10n.string("menu.setup-guide"),
            "",
            L10n.string("menu.quit"),
        ])
        Self.retainedStatusItemControllers.append(controller)
    }

    func testStatusItemWindowIsPlacedInTheMenuBarBySystem() throws {
        try XCTSkipUnless(
            Bundle.main.bundleIdentifier == "app.snapspool.Snapspool",
            "ステータス項目の実配置はアプリをテストホストにしたxcodebuild testで検証する"
        )
        _ = NSApplication.shared
        let menu = MenuBarActions(
            clipboardMonitor: ClipboardMonitor(pasteboard: FakeMenuPasteboard()) { _ in }
        ).makeMenu()
        let controller = MenuBarStatusItemController(menu: menu)
        let button = try XCTUnwrap(controller.statusItem.button)
        let window = try XCTUnwrap(button.window)
        XCTAssertTrue(controller.statusItem.isVisible)

        // 検証するのは「項目がメニューバーの帯に実際に配置されたか」。
        //
        // 以前はCGWindowListで所有者がコントロールセンターであることまで見ていたが、
        // この方式は2つの理由で安定しない:
        // ・`NSWindow.windowNumber` が `CGWindowID` に収まらない値（0x3_0000_0000）を
        //   返すようになり、UInt32変換で異常終了する
        // ・位置で引く方式に変えても、その点に重なる他アプリのウィンドウ次第で
        //   コントロールセンターが一覧に出ないことがある
        // メニューバーに出ているかどうかは配置位置で判定できるため、そこに絞る。
        var frame = window.frame
        let deadline = Date().addingTimeInterval(5)
        while !Self.isInMenuBarStrip(frame), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            frame = window.frame
        }

        XCTAssertGreaterThan(frame.width, 0, "ステータス項目のウィンドウに幅がない")
        XCTAssertTrue(
            Self.isInMenuBarStrip(frame),
            "ステータス項目がどの画面のメニューバーにも配置されていない。frame=\(frame)"
        )
        Self.retainedStatusItemControllers.append(controller)
    }

    /// ウィンドウがいずれかの画面のメニューバーの帯に収まっているか
    private static func isInMenuBarStrip(_ frame: CGRect) -> Bool {
        NSScreen.screens.contains { screen in
            screen.frame.intersects(frame) && frame.minY >= screen.frame.maxY - 40
        }
    }

    func testStatusItemControllerKeepsMenuUsableWhenAssetLoadingFails() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
            "テストバンドルを直接実行した場合はステータス項目を生成できないためスキップ（xcodebuild test でのみ実行される）"
        )
        let menu = MenuBarActions(
            clipboardMonitor: ClipboardMonitor(pasteboard: FakeMenuPasteboard()) { _ in }
        ).makeMenu()

        let controller = MenuBarStatusItemController(menu: menu, loadImage: { nil })
        let button = try XCTUnwrap(controller.statusItem.button)

        XCTAssertNil(button.image)
        XCTAssertEqual(button.title, "Snapspool")
        XCTAssertEqual(button.toolTip, "Snapspool")
        XCTAssertTrue(controller.statusItem.menu === menu)
        XCTAssertTrue(controller.statusItem.isVisible)
        Self.retainedStatusItemControllers.append(controller)
    }

    func testBundledMenuBarAssetLoadsAsTemplateWithoutSFSymbolFallback() throws {
        let image = try XCTUnwrap(MenuBarStatusItemController.loadMenuBarImage(
            from: Bundle(for: Self.self)
        ))

        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.accessibilityDescription, "Snapspool")
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
    }

    func testLaunchedBuiltAppUsesImageFromApplicationBundleForStatusItem() throws {
        try XCTSkipUnless(
            Bundle.main.bundleIdentifier == "app.snapspool.Snapspool",
            "ビルドしたアプリをテストホストとして起動するxcodebuild testで検証する"
        )
        XCTAssertEqual(Bundle.main.bundleURL.pathExtension, "app")
        XCTAssertEqual(
            Bundle(for: MenuBarStatusItemController.self).bundleURL.pathExtension,
            "framework",
            "実装フレームワークと画像を持つアプリのバンドルが分かれていることを前提に検証する"
        )

        let menu = MenuBarActions(
            clipboardMonitor: ClipboardMonitor(pasteboard: FakeMenuPasteboard()) { _ in }
        ).makeMenu()
        let controller = MenuBarStatusItemController(menu: menu)
        let button = try XCTUnwrap(controller.statusItem.button)
        let image = try XCTUnwrap(
            button.image,
            "起動中のSnapspool.appのAssets.carからメニューバー画像を読めていない"
        )

        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.accessibilityDescription, "Snapspool")
        XCTAssertEqual(button.title, "")
        Self.retainedStatusItemControllers.append(controller)
    }

    func testMissingMenuBarAssetUsesVisibleTextFallback() {
        let button = NSButton()

        MenuBarStatusItemController.configure(button: button, image: nil)

        XCTAssertNil(button.image)
        XCTAssertEqual(button.title, "Snapspool")
        XCTAssertEqual(button.toolTip, "Snapspool")
    }

    func testRuntimeOwnsConfiguredStatusItemController() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
            "テストバンドルを直接実行した場合はステータス項目を生成できないためスキップ（xcodebuild test でのみ実行される）"
        )
        let runtime = SnapspoolRuntime(imageSaveNotifier: SilentMenuImageSaveNotifier())
        let statusItem = runtime.statusItemController.statusItem

        XCTAssertNotNil(statusItem.button)
        XCTAssertNotNil(statusItem.button?.image)
        XCTAssertEqual(statusItem.button?.toolTip, "Snapspool")
        XCTAssertEqual(try XCTUnwrap(statusItem.menu).items.map(\.title), [
            L10n.string("menu.history"),
            L10n.string("menu.pause-monitoring"),
            L10n.string("menu.settings"),
            L10n.string("menu.setup-guide"),
            "",
            L10n.string("menu.quit"),
        ])
        Self.retainedRuntimes.append(runtime)
    }

    func testRuntimeRefreshesMenuAfterBothStartupHotKeyRegistrationsFail() throws {
        let suiteName = "MenuBarActionsTests.hotKeyFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuredShortcut = GlobalShortcut(
            keyCode: UInt32(kVK_ANSI_B),
            modifiers: UInt32(cmdKey | optionKey)
        )
        defaults.set(Int(configuredShortcut.keyCode), forKey: "settings.shortcut.keyCode")
        defaults.set(Int(configuredShortcut.modifiers), forKey: "settings.shortcut.modifiers")
        let registrar = FailingMenuHotKeyRegistrar()
        var historyOpenCount = 0
        var presentedMenu: NSMenu?
        let runtime = SnapspoolRuntime(
            imageSaveNotifier: SilentMenuImageSaveNotifier(),
            settings: AppSettings(defaults: defaults),
            hotKeyRegistrar: registrar,
            clipboardPasteboard: FakeMenuPasteboard(),
            showHistoryPicker: { historyOpenCount += 1 },
            presentStatusMenu: { presentedMenu = $0 },
            presentFirstLaunchSetupOnStart: {},
            createStatusItem: false
        )
        defer { runtime.stop() }

        runtime.start()

        XCTAssertEqual(registrar.attempts, [configuredShortcut, .defaultShortcut])
        let refreshedMenu = try XCTUnwrap(presentedMenu)
        XCTAssertEqual(refreshedMenu.items.map(\.title), [
            L10n.string("menu.history"),
            L10n.string("menu.shortcut-warning"),
            L10n.string("menu.pause-monitoring"),
            L10n.string("menu.settings"),
            L10n.string("menu.setup-guide"),
            "",
            L10n.string("menu.quit"),
        ])
        XCTAssertFalse(try XCTUnwrap(refreshedMenu.item(at: 1)).isEnabled)

        activate(try XCTUnwrap(refreshedMenu.item(at: 0)))
        XCTAssertEqual(historyOpenCount, 1)
    }

    func testBuiltMenuContainsRequiredItemsInOrder() {
        let actions = MenuBarActions(
            clipboardMonitor: ClipboardMonitor(pasteboard: FakeMenuPasteboard()) { _ in }
        )

        let menu = actions.makeMenu()

        XCTAssertEqual(menu.items.map(\.title), [
            L10n.string("menu.history"),
            L10n.string("menu.pause-monitoring"),
            L10n.string("menu.settings"),
            L10n.string("menu.setup-guide"),
            "",
            L10n.string("menu.quit"),
        ])
        XCTAssertEqual(menu.items.map(\.isSeparatorItem), [false, false, false, false, true, false])
    }

    func testBuiltMenuDispatchesHistoryAction() throws {
        var historyOpenCount = 0
        let actions = MenuBarActions(
            clipboardMonitor: ClipboardMonitor(pasteboard: FakeMenuPasteboard()) { _ in },
            showHistoryPicker: { historyOpenCount += 1 }
        )
        let menu = actions.makeMenu()
        let historyItem = try XCTUnwrap(menu.item(at: 0))

        activate(historyItem)

        XCTAssertEqual(historyOpenCount, 1)
    }

    func testBuiltMenuDispatchesSettingsAction() throws {
        var settingsOpenCount = 0
        let actions = MenuBarActions(
            clipboardMonitor: ClipboardMonitor(pasteboard: FakeMenuPasteboard()) { _ in },
            showSettings: { settingsOpenCount += 1 }
        )
        let settingsItem = try XCTUnwrap(actions.makeMenu().item(at: 2))

        activate(settingsItem)

        XCTAssertEqual(settingsOpenCount, 1)
    }

    func testBuiltMenuDispatchesSetupGuideAction() throws {
        var setupGuideOpenCount = 0
        let actions = MenuBarActions(
            clipboardMonitor: ClipboardMonitor(pasteboard: FakeMenuPasteboard()) { _ in },
            showSetupGuide: { setupGuideOpenCount += 1 }
        )
        let setupGuideItem = try XCTUnwrap(actions.makeMenu().item(at: 3))

        XCTAssertEqual(setupGuideItem.title, L10n.string("menu.setup-guide"))
        activate(setupGuideItem)

        XCTAssertEqual(setupGuideOpenCount, 1)
    }

    func testBuiltMenuOpensConfiguredPrivacyPolicyURL() throws {
        let privacyPolicyURL = try XCTUnwrap(URL(string: "https://example.com/privacy"))
        var openedURL: URL?
        let actions = MenuBarActions(
            clipboardMonitor: ClipboardMonitor(pasteboard: FakeMenuPasteboard()) { _ in },
            privacyPolicyURL: privacyPolicyURL,
            openURL: { openedURL = $0 }
        )

        let menu = actions.makeMenu()
        let privacyPolicyItem = try XCTUnwrap(menu.item(at: 4))

        XCTAssertEqual(privacyPolicyItem.title, L10n.string("menu.privacy-policy"))
        activate(privacyPolicyItem)
        XCTAssertEqual(openedURL, privacyPolicyURL)
    }

    func testBuiltMenuOmitsPrivacyPolicyWhenURLIsUnset() {
        let actions = MenuBarActions(
            clipboardMonitor: ClipboardMonitor(pasteboard: FakeMenuPasteboard()) { _ in },
            privacyPolicyURL: nil
        )

        XCTAssertNil(actions.makeMenu().item(withTitle: L10n.string("menu.privacy-policy")))
    }

    func testRegistrationWarningIsShownWithoutDisablingHistoryMenu() throws {
        var historyOpenCount = 0
        let actions = MenuBarActions(
            clipboardMonitor: ClipboardMonitor(pasteboard: FakeMenuPasteboard()) { _ in },
            showHistoryPicker: { historyOpenCount += 1 },
            hasHotKeyRegistrationWarning: { true }
        )

        let menu = actions.makeMenu()

        XCTAssertEqual(
            menu.items.map(\.title),
            [
                L10n.string("menu.history"),
                L10n.string("menu.shortcut-warning"),
                L10n.string("menu.pause-monitoring"),
                L10n.string("menu.settings"),
                L10n.string("menu.setup-guide"),
                "",
                L10n.string("menu.quit"),
            ]
        )
        XCTAssertFalse(try XCTUnwrap(menu.item(at: 1)).isEnabled)
        activate(try XCTUnwrap(menu.item(at: 0)))
        XCTAssertEqual(historyOpenCount, 1)
    }

    func testBuiltMenuPauseActionTogglesMonitorAndUpdatesVisibleTitle() throws {
        let monitoringState = MonitoringState()
        let monitor = ClipboardMonitor(
            pasteboard: FakeMenuPasteboard(),
            monitoringState: monitoringState
        ) { _ in }
        let actions = MenuBarActions(clipboardMonitor: monitor)
        let pauseItem = try XCTUnwrap(actions.makeMenu().item(at: 1))
        var publishedStates: [Bool] = []
        let stateUpdates = monitoringState.$isPaused
            .dropFirst()
            .sink { publishedStates.append($0) }

        activate(pauseItem)
        XCTAssertTrue(monitor.isPaused)
        XCTAssertTrue(monitoringState.isPaused)
        XCTAssertEqual(pauseItem.title, L10n.string("menu.resume-monitoring"))
        XCTAssertEqual(
            try XCTUnwrap(actions.makeMenu().item(at: 1)).title,
            L10n.string("menu.resume-monitoring")
        )

        activate(pauseItem)
        XCTAssertFalse(monitor.isPaused)
        XCTAssertFalse(monitoringState.isPaused)
        XCTAssertEqual(pauseItem.title, L10n.string("menu.pause-monitoring"))
        XCTAssertEqual(
            try XCTUnwrap(actions.makeMenu().item(at: 1)).title,
            L10n.string("menu.pause-monitoring")
        )
        XCTAssertEqual(publishedStates, [true, false])
        withExtendedLifetime(stateUpdates) {}
    }

    func testBuiltMenuQuitActionTerminatesApplication() throws {
        var terminationCount = 0
        let actions = MenuBarActions(
            clipboardMonitor: ClipboardMonitor(pasteboard: FakeMenuPasteboard()) { _ in },
            terminateApplication: { terminationCount += 1 }
        )
        let quitItem = try XCTUnwrap(actions.makeMenu().item(at: 5))

        XCTAssertEqual(terminationCount, 0)

        activate(quitItem)
        XCTAssertEqual(terminationCount, 1)
    }

    private func activate(_ item: NSMenuItem) {
        XCTAssertTrue(
            NSApplication.shared.sendAction(item.action!, to: item.target, from: item),
            "Menu item action was not dispatched: \(item.title)"
        )
    }

}

@MainActor
private final class FakeMenuPasteboard: ClipboardPasteboardReading {
    var changeCount = 0
    var items: [any PasteboardItemReading] = []
}

@MainActor
private final class FailingMenuHotKeyRegistrar: GlobalHotKeyRegistering {
    private(set) var attempts: [GlobalShortcut] = []

    func register(
        _ shortcut: GlobalShortcut,
        handler: @MainActor @Sendable @escaping () -> Void
    ) -> Bool {
        attempts.append(shortcut)
        return false
    }

    func unregister() {}
}

private struct SilentMenuImageSaveNotifier: ImageSaveNotifying {
    func notifyDestinationSaveFailed() {}
    func notifyFallbackSaveFailed() {}
}
