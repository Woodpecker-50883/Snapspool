import AppKit
import Combine
import XCTest
@testable import Snapspool

@MainActor
final class MenuBarActionsTests: XCTestCase {
    func testBuiltMenuContainsRequiredItemsInOrder() {
        let actions = MenuBarActions(
            clipboardMonitor: ClipboardMonitor(pasteboard: FakeMenuPasteboard()) { _ in }
        )

        let menu = actions.makeMenu()

        XCTAssertEqual(menu.items.map(\.title), [
            L10n.string("menu.history"),
            L10n.string("menu.pause-monitoring"),
            L10n.string("menu.settings"),
            "",
            L10n.string("menu.quit"),
        ])
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
