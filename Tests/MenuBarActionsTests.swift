import AppKit
import Combine
import XCTest
@testable import Snapspool

@MainActor
final class MenuBarActionsTests: XCTestCase {
    // Keep status items alive for the managed test session.
    private static var retainedStatusItemControllers: [MenuBarStatusItemController] = []
    private static var retainedRuntimes: [SnapspoolRuntime] = []

    func testStatusItemControllerConfiguresButtonAndRequiredMenu() throws {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else {
            return
        }
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

    func testStatusItemControllerKeepsMenuUsableWhenAssetLoadingFails() throws {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else {
            return
        }
        let menu = MenuBarActions(
            clipboardMonitor: ClipboardMonitor(pasteboard: FakeMenuPasteboard()) { _ in }
        ).makeMenu()

        let controller = MenuBarStatusItemController(menu: menu, loadImage: { nil })
        let button = try XCTUnwrap(controller.statusItem.button)

        XCTAssertNil(button.image)
        XCTAssertEqual(button.title, "Snapspool")
        XCTAssertEqual(button.toolTip, "Snapspool")
        XCTAssertTrue(controller.statusItem.menu === menu)
        XCTAssertGreaterThan(controller.statusItem.length, 0)
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

    func testMissingMenuBarAssetUsesVisibleTextFallback() {
        let button = NSButton()

        MenuBarStatusItemController.configure(button: button, image: nil)

        XCTAssertNil(button.image)
        XCTAssertEqual(button.title, "Snapspool")
        XCTAssertEqual(button.toolTip, "Snapspool")
    }

    func testRuntimeOwnsConfiguredStatusItemController() throws {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else {
            return
        }
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

    func testLaunchedAppCreatesMenuBarLayerWindowAndRemainsAccessoryApp() throws {
        // Direct xctest bundle execution is the sandbox-compatible local path,
        // but it has no testmanager launch session in which to start a GUI app.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else {
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        let launchResult = ApplicationLaunchResult()
        NSWorkspace.shared.openApplication(
            at: try builtAppURL(),
            configuration: configuration
        ) { application, error in
            launchResult.record(application: application, error: error)
        }

        let launchDeadline = Date().addingTimeInterval(5)
        var result = launchResult.snapshot()
        while result.application == nil, result.error == nil, Date() < launchDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            result = launchResult.snapshot()
        }
        XCTAssertNil(result.error)
        let application = try XCTUnwrap(result.application)
        defer {
            application.terminate()
        }

        let deadline = Date().addingTimeInterval(5)
        var menuBarWindows: [[String: Any]] = []
        repeat {
            menuBarWindows = windows(ownedBy: application.processIdentifier, layer: 25)
            if !menuBarWindows.isEmpty { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while !application.isTerminated && Date() < deadline

        XCTAssertFalse(application.isTerminated, "Snapspool exited during launch")
        XCTAssertEqual(menuBarWindows.count, 1, "Windows: \(allWindows(ownedBy: application.processIdentifier))")
        XCTAssertEqual(application.activationPolicy, .accessory)
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

    private func windows(ownedBy processID: Int32, layer: Int) -> [[String: Any]] {
        allWindows(ownedBy: processID).filter {
            ($0[kCGWindowLayer as String] as? Int) == layer
        }
    }

    private func allWindows(ownedBy processID: Int32) -> [[String: Any]] {
        let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        return windows.filter {
            ($0[kCGWindowOwnerPID as String] as? Int32) == processID
                || ($0[kCGWindowOwnerPID as String] as? Int) == Int(processID)
        }
    }

    private func builtAppURL() throws -> URL {
        var directory = Bundle(for: Self.self).bundleURL

        for _ in 0..<8 {
            if directory.lastPathComponent == "Snapspool.app" {
                return directory
            }
            let sibling = directory
                .deletingLastPathComponent()
                .appendingPathComponent("Snapspool.app", isDirectory: true)
            if FileManager.default.fileExists(atPath: sibling.path) {
                return sibling
            }
            directory.deleteLastPathComponent()
        }

        return try XCTUnwrap(
            nil,
            "Could not locate built Snapspool.app next to \(Bundle(for: Self.self).bundleURL.path)"
        )
    }
}

@MainActor
private final class FakeMenuPasteboard: ClipboardPasteboardReading {
    var changeCount = 0
    var items: [any PasteboardItemReading] = []
}

private final class ApplicationLaunchResult: @unchecked Sendable {
    private let lock = NSLock()
    private var application: NSRunningApplication?
    private var error: Error?

    func record(application: NSRunningApplication?, error: Error?) {
        lock.withLock {
            self.application = application
            self.error = error
        }
    }

    func snapshot() -> (application: NSRunningApplication?, error: Error?) {
        lock.withLock { (application, error) }
    }
}

private struct SilentMenuImageSaveNotifier: ImageSaveNotifying {
    func notifyDestinationSaveFailed() {}
    func notifyFallbackSaveFailed() {}
}
