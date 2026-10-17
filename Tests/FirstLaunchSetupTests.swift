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
        XCTAssertTrue(english.autoPasteInstructions.contains("1."))
        XCTAssertTrue(english.autoPasteInstructions.contains("macOS access dialog"))
        XCTAssertTrue(english.emptyHistoryRestartNote.contains("history is empty"))
        XCTAssertTrue(english.emptyHistoryRestartNote.contains("Screenshot Setup Guide"))
        XCTAssertEqual(english.openSettingsButtonTitle, "Open Keyboard Shortcuts…")
        XCTAssertEqual(english.enableAutoPasteButtonTitle, "Enable Automatic Paste…")
        XCTAssertEqual(english.permissionUnauthorizedStatus, "Automatic paste access: Not allowed")
        XCTAssertTrue(english.permissionRestartRequiredStatus.contains("restart Snapspool"))
        XCTAssertEqual(english.permissionActiveStatus, "Automatic paste access: Active")
        XCTAssertTrue(english.manualSettingsPath.contains("System Settings > Keyboard > Keyboard Shortcuts > Screenshots"))

        XCTAssertTrue(japanese.introduction.contains("スクリーンショットをクリップボードにコピー"))
        XCTAssertTrue(japanese.shortcutInstructions.contains("ファイルとして保存"))
        XCTAssertTrue(japanese.shortcutInstructions.contains("クリップボードにコピー"))
        XCTAssertTrue(japanese.destinationInstructions.contains("~/Pictures/Snapspool/"))
        XCTAssertTrue(japanese.destinationInstructions.contains("設定画面"))
        XCTAssertTrue(japanese.autoPasteInstructions.contains("1."))
        XCTAssertTrue(japanese.autoPasteInstructions.contains("macOSの権限ダイアログ"))
        XCTAssertTrue(japanese.emptyHistoryRestartNote.contains("履歴が空"))
        XCTAssertTrue(japanese.emptyHistoryRestartNote.contains("スクリーンショットの設定"))
        XCTAssertEqual(japanese.openSettingsButtonTitle, "キーボードショートカットを開く…")
        XCTAssertEqual(japanese.enableAutoPasteButtonTitle, "自動貼り付けを有効にする…")
        XCTAssertEqual(japanese.permissionUnauthorizedStatus, "自動貼り付けの権限：未許可")
        XCTAssertTrue(japanese.permissionRestartRequiredStatus.contains("再起動が必要"))
        XCTAssertEqual(japanese.permissionActiveStatus, "自動貼り付けの権限：有効")
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

    func testSetupWindowTracksPermissionAndCompletesRestartWithoutModalAlerts() throws {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var scheduledPermissionRecheck: (@MainActor () -> Void)?
        var permissionRequestCount = 0
        var displayedAlerts: [NSAlert] = []
        var openedURL: URL?
        var relaunchSequence: [String] = []
        let notifier = SystemAutoPasteNotifier(
            openURL: {
                openedURL = $0
                return true
            },
            runAlert: {
                displayedAlerts.append($0)
                return .alertFirstButtonReturn
            },
            requestAuthorization: { completion in
                permissionRequestCount += 1
                completion(false)
            },
            isAuthorized: { false },
            isApplicationActive: { true },
            schedulePermissionRecheck: { _, recheck in scheduledPermissionRecheck = recheck },
            defaults: defaults,
            prepareForRelaunch: { relaunchSequence.append("prepare") },
            relaunchApplication: { _ in
                relaunchSequence.append("launch")
                return true
            },
            terminateCurrentApplication: { relaunchSequence.append("terminate") }
        )
        let controller = FirstLaunchSetupController(
            defaults: defaults,
            autoPastePermissionGuide: notifier
        )
        let hostingController = try XCTUnwrap(
            controller.window?.contentViewController as? NSHostingController<FirstLaunchSetupView>
        )
        controller.show()

        XCTAssertEqual(hostingController.rootView.model.permissionState, .unauthorized)
        XCTAssertFalse(hostingController.rootView.showsRestartButton)

        hostingController.rootView.enableAutoPaste()

        XCTAssertEqual(permissionRequestCount, 1)
        XCTAssertEqual(openedURL, SystemAutoPasteNotifier.accessibilitySettingsURL)
        XCTAssertTrue(displayedAlerts.isEmpty)

        scheduledPermissionRecheck?()

        XCTAssertEqual(hostingController.rootView.model.permissionState, .restartRequired)
        XCTAssertTrue(hostingController.rootView.showsRestartButton)
        XCTAssertTrue(displayedAlerts.isEmpty)

        hostingController.rootView.restartAutoPaste()
        XCTAssertEqual(relaunchSequence, ["prepare", "launch", "terminate"])
    }

    func testRestartRequiredStateSurvivesFallbackAndFailedPermissionNotifications() throws {
        var scheduledPermissionRechecks: [(@MainActor () -> Void)] = []
        var permissionCompletions: [(Bool) -> Void] = []
        var displayedAlerts: [NSAlert] = []
        let notifier = SystemAutoPasteNotifier(
            openURL: { _ in true },
            runAlert: {
                displayedAlerts.append($0)
                return .alertFirstButtonReturn
            },
            requestAuthorization: { permissionCompletions.append($0) },
            isAuthorized: { false },
            isApplicationActive: { true },
            schedulePermissionRecheck: { _, recheck in
                scheduledPermissionRechecks.append(recheck)
            }
        )
        let controller = FirstLaunchSetupController(autoPastePermissionGuide: notifier)
        let view = try XCTUnwrap(
            controller.window?.contentViewController as? NSHostingController<FirstLaunchSetupView>
        ).rootView
        controller.show()

        view.enableAutoPaste()
        permissionCompletions.removeFirst()(false)
        scheduledPermissionRechecks.removeLast()()
        XCTAssertEqual(view.model.permissionState, .restartRequired)
        XCTAssertTrue(view.showsRestartButton)

        notifier.notifyManualPasteRequired()
        XCTAssertEqual(view.model.permissionState, .restartRequired)
        XCTAssertTrue(view.showsRestartButton)
        XCTAssertTrue(displayedAlerts.isEmpty)

        view.enableAutoPaste()
        permissionCompletions.removeFirst()(false)
        XCTAssertEqual(view.model.permissionState, .restartRequired)
        XCTAssertTrue(view.showsRestartButton)
        XCTAssertTrue(displayedAlerts.isEmpty)
    }

    func testSetupRelaunchReopensGuideAsActiveWithoutPermissionEnabledAlert() throws {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var scheduledPermissionRecheck: (@MainActor () -> Void)?
        var oldInstanceAlerts: [NSAlert] = []
        let oldNotifier = SystemAutoPasteNotifier(
            openURL: { _ in true },
            runAlert: {
                oldInstanceAlerts.append($0)
                return .alertFirstButtonReturn
            },
            requestAuthorization: { $0(false) },
            isAuthorized: { false },
            isApplicationActive: { true },
            schedulePermissionRecheck: { _, recheck in scheduledPermissionRecheck = recheck },
            defaults: defaults,
            relaunchApplication: { _ in true },
            terminateCurrentApplication: {}
        )
        let oldController = FirstLaunchSetupController(
            defaults: defaults,
            autoPastePermissionGuide: oldNotifier
        )

        XCTAssertTrue(oldController.showIfNeeded())
        let oldView = try XCTUnwrap(
            oldController.window?.contentViewController as? NSHostingController<FirstLaunchSetupView>
        ).rootView
        oldView.enableAutoPaste()
        scheduledPermissionRecheck?()
        XCTAssertEqual(oldView.model.permissionState, .restartRequired)
        oldView.restartAutoPaste()

        var newInstanceAlerts: [NSAlert] = []
        let newNotifier = SystemAutoPasteNotifier(
            runAlert: {
                newInstanceAlerts.append($0)
                return .alertFirstButtonReturn
            },
            isAuthorized: { true },
            defaults: defaults
        )
        let newController = FirstLaunchSetupController(
            defaults: defaults,
            autoPastePermissionGuide: newNotifier
        )

        XCTAssertTrue(newController.showIfNeeded())
        let newView = try XCTUnwrap(
            newController.window?.contentViewController as? NSHostingController<FirstLaunchSetupView>
        ).rootView
        XCTAssertTrue(try XCTUnwrap(newController.window).isVisible)
        XCTAssertEqual(newView.model.permissionState, .active)
        XCTAssertEqual(newView.permissionStatusText, newView.content.permissionActiveStatus)
        XCTAssertFalse(newView.showsRestartButton)
        XCTAssertTrue(oldInstanceAlerts.isEmpty)
        XCTAssertTrue(newInstanceAlerts.isEmpty)
        XCTAssertFalse(newController.showIfNeeded(), "The setup relaunch hand-off must be consumed once")
    }

    func testSetupWindowAutomaticallyReflectsGrantedPermissionAndSuppressesFallbackModal() throws {
        var scheduledPermissionRechecks: [(@MainActor () -> Void)] = []
        var isAuthorized = false
        var displayedAlerts: [NSAlert] = []
        let notifier = SystemAutoPasteNotifier(
            openURL: { _ in true },
            runAlert: {
                displayedAlerts.append($0)
                return .alertFirstButtonReturn
            },
            requestAuthorization: { $0(false) },
            isAuthorized: { isAuthorized },
            isApplicationActive: { false },
            schedulePermissionRecheck: { _, recheck in scheduledPermissionRechecks.append(recheck) }
        )
        let controller = FirstLaunchSetupController(autoPastePermissionGuide: notifier)
        let hostingController = try XCTUnwrap(
            controller.window?.contentViewController as? NSHostingController<FirstLaunchSetupView>
        )
        controller.show()
        hostingController.rootView.enableAutoPaste()

        notifier.notifyManualPasteRequired()
        XCTAssertTrue(displayedAlerts.isEmpty)

        isAuthorized = true
        scheduledPermissionRechecks.removeFirst()()

        XCTAssertEqual(hostingController.rootView.model.permissionState, .active)
        XCTAssertFalse(hostingController.rootView.showsRestartButton)
        XCTAssertEqual(
            hostingController.rootView.permissionStatusText,
            hostingController.rootView.content.permissionActiveStatus
        )
        XCTAssertTrue(displayedAlerts.isEmpty)
    }

    func testOpenSetupWindowRefreshesPermissionWithoutAnotherUserAction() throws {
        var scheduledPermissionRechecks: [(@MainActor () -> Void)] = []
        var isAuthorized = false
        let notifier = SystemAutoPasteNotifier(
            isAuthorized: { isAuthorized },
            schedulePermissionRecheck: { _, recheck in scheduledPermissionRechecks.append(recheck) }
        )
        let controller = FirstLaunchSetupController(autoPastePermissionGuide: notifier)
        let hostingController = try XCTUnwrap(
            controller.window?.contentViewController as? NSHostingController<FirstLaunchSetupView>
        )

        controller.show()
        XCTAssertEqual(hostingController.rootView.model.permissionState, .unauthorized)
        XCTAssertEqual(scheduledPermissionRechecks.count, 1)

        isAuthorized = true
        scheduledPermissionRechecks.removeFirst()()

        XCTAssertEqual(hostingController.rootView.model.permissionState, .active)
        XCTAssertEqual(scheduledPermissionRechecks.count, 1)
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
