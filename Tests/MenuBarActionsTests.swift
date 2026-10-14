import AppKit
import XCTest
@testable import Snapspool

@MainActor
final class MenuBarActionsTests: XCTestCase {
    func testBuiltMenuContainsRequiredItemsInOrder() {
        let actions = MenuBarActions(
            clipboardMonitor: ClipboardMonitor(pasteboard: FakeMenuPasteboard()) { _ in }
        )

        let menu = actions.makeMenu()

        XCTAssertEqual(menu.items.map(\.title), ["履歴", "監視の一時停止", "設定", "", "終了"])
        XCTAssertEqual(menu.items.map(\.isSeparatorItem), [false, false, false, true, false])
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
            ["履歴", "⚠︎ ショートカットを登録できません", "監視の一時停止", "設定", "", "終了"]
        )
        XCTAssertFalse(try XCTUnwrap(menu.item(at: 1)).isEnabled)
        activate(try XCTUnwrap(menu.item(at: 0)))
        XCTAssertEqual(historyOpenCount, 1)
    }

    func testBuiltMenuPauseActionTogglesMonitorAndUpdatesVisibleTitle() throws {
        let monitor = ClipboardMonitor(pasteboard: FakeMenuPasteboard()) { _ in }
        let actions = MenuBarActions(clipboardMonitor: monitor)
        let pauseItem = try XCTUnwrap(actions.makeMenu().item(at: 1))

        activate(pauseItem)
        XCTAssertTrue(monitor.isPaused)
        XCTAssertEqual(pauseItem.title, "監視を再開")

        activate(pauseItem)
        XCTAssertFalse(monitor.isPaused)
        XCTAssertEqual(pauseItem.title, "監視の一時停止")
    }

    func testBuiltMenuQuitActionTerminatesApplication() throws {
        var terminationCount = 0
        let actions = MenuBarActions(
            clipboardMonitor: ClipboardMonitor(pasteboard: FakeMenuPasteboard()) { _ in },
            terminateApplication: { terminationCount += 1 }
        )
        let quitItem = try XCTUnwrap(actions.makeMenu().item(at: 4))

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
