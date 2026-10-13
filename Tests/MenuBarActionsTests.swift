import XCTest
@testable import Snapspool

@MainActor
final class MenuBarActionsTests: XCTestCase {
    func testMenuContainsRequiredItemsInOrder() {
        XCTAssertEqual(
            MenuBarItem.allCases,
            [.pauseMonitoring, .settings, .quit]
        )
        XCTAssertEqual(MenuBarItem.pauseMonitoring.rawValue, "監視の一時停止")
        XCTAssertEqual(MenuBarItem.settings.rawValue, "設定")
        XCTAssertEqual(MenuBarItem.quit.rawValue, "終了")
    }

    func testPauseActionTogglesMonitoringAndDoesNotTerminateApplication() {
        var terminationCount = 0
        let monitor = ClipboardMonitor(pasteboard: FakeMenuPasteboard()) { _ in }
        let actions = MenuBarActions(clipboardMonitor: monitor) {
            terminationCount += 1
        }

        XCTAssertFalse(actions.isMonitoringPaused)
        XCTAssertEqual(actions.monitoringMenuTitle, "監視の一時停止")

        actions.pauseMonitoring()
        XCTAssertTrue(actions.isMonitoringPaused)
        XCTAssertEqual(actions.monitoringMenuTitle, "監視を再開")

        actions.pauseMonitoring()
        XCTAssertFalse(actions.isMonitoringPaused)
        XCTAssertEqual(actions.monitoringMenuTitle, "監視の一時停止")

        actions.openSettings()

        XCTAssertEqual(terminationCount, 0)
    }

    func testQuitTerminatesApplication() {
        var terminationCount = 0
        let actions = MenuBarActions(clipboardMonitor: ClipboardMonitor(pasteboard: FakeMenuPasteboard()) { _ in }) {
            terminationCount += 1
        }

        actions.quit()

        XCTAssertEqual(terminationCount, 1)
    }
}

@MainActor
private final class FakeMenuPasteboard: ClipboardPasteboardReading {
    var changeCount = 0
    var items: [any PasteboardItemReading] = []
}
