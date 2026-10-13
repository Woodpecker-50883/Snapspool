import XCTest

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

    func testPlaceholderActionsDoNotTerminateApplication() {
        var terminationCount = 0
        let actions = MenuBarActions {
            terminationCount += 1
        }

        actions.pauseMonitoring()
        actions.openSettings()

        XCTAssertEqual(terminationCount, 0)
    }

    func testQuitTerminatesApplication() {
        var terminationCount = 0
        let actions = MenuBarActions {
            terminationCount += 1
        }

        actions.quit()

        XCTAssertEqual(terminationCount, 1)
    }
}
