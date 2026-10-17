import AppKit
import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import Snapspool

@MainActor
final class AutoPasteTests: XCTestCase {
    func testAutoPasteIsEnabledByDefaultAndDisabledSettingSurvivesRelaunch() {
        let suiteName = "AutoPasteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)

        XCTAssertTrue(settings.autoPasteEnabled)
        settings.setAutoPasteEnabled(false)
        XCTAssertFalse(settings.autoPasteEnabled)
        XCTAssertFalse(AppSettings(defaults: defaults).autoPasteEnabled)
    }

    func testDisabledAutoPasteDoesNotRequestPermissionOrSendAnEvent() {
        let log = AutoPasteCallLog()
        let controller = makeController(log: log, isAuthorized: true)

        XCTAssertTrue(log.calls.isEmpty, "Creating the controller must not request permission")
        controller.pasteIfEnabled(false)

        XCTAssertTrue(log.calls.isEmpty)
    }

    func testPermissionIsRequestedOnFirstPasteAndDeniedAccessFallsBackWithoutSending() {
        let log = AutoPasteCallLog()
        let controller = makeController(log: log, isAuthorized: false)

        XCTAssertTrue(log.calls.isEmpty, "Permission must not be requested at app startup")
        controller.pasteIfEnabled(true)

        XCTAssertEqual(log.calls, ["authorize", "notify"])
    }

    func testFirstPasteDoesNotShowFallbackWhileSystemPermissionDialogIsOpen() {
        let log = AutoPasteCallLog()
        let authorization = DeferredAuthorization(log: log)
        let controller = AutoPasteController(
            authorization: authorization,
            eventSender: LoggedEventSender(log: log),
            notifier: LoggedAutoPasteNotifier(log: log),
            targetApplicationProvider: LoggedTargetApplicationProvider(
                application: LoggedTargetApplication(name: "target", log: log)
            )
        )

        controller.captureTargetApplication()
        controller.pasteIfEnabled(true)
        XCTAssertEqual(log.calls, ["authorize"])

        authorization.finish(isAuthorized: false)
        XCTAssertEqual(log.calls, ["authorize", "notify"])
    }

    func testFirstPasteContinuesWithoutFallbackWhenSystemDialogGrantsAccess() {
        let log = AutoPasteCallLog()
        let authorization = DeferredAuthorization(log: log)
        let controller = AutoPasteController(
            authorization: authorization,
            eventSender: LoggedEventSender(log: log),
            notifier: LoggedAutoPasteNotifier(log: log),
            targetApplicationProvider: LoggedTargetApplicationProvider(
                application: LoggedTargetApplication(name: "target", log: log)
            )
        )

        controller.captureTargetApplication()
        controller.pasteIfEnabled(true)
        authorization.finish(isAuthorized: true)

        XCTAssertEqual(log.calls, ["authorize", "activate:target", "send"])
    }

    func testPermissionNoticeOffersAccessibilitySettingsAndOpensTheAccessibilityPane() {
        var openedURL: URL?
        var displayedAlert: NSAlert?
        let notifier = SystemAutoPasteNotifier(
            openURL: {
                openedURL = $0
                return true
            },
            runAlert: {
                displayedAlert = $0
                return .alertFirstButtonReturn
            }
        )

        notifier.notifyManualPasteRequired()

        XCTAssertEqual(
            displayedAlert?.buttons.map(\.title),
            [
                L10n.string("autopaste.open-accessibility-settings"),
                L10n.string("common.ok"),
            ]
        )
        XCTAssertEqual(
            displayedAlert?.informativeText,
            L10n.string("autopaste.permission-required-message")
        )
        XCTAssertEqual(openedURL, SystemAutoPasteNotifier.accessibilitySettingsURL)
    }

    func testPermissionNoticeKeepsSettingsClosedWhenOKIsChosen() {
        var openedURLs: [URL] = []
        let notifier = SystemAutoPasteNotifier(
            openURL: {
                openedURLs.append($0)
                return true
            },
            runAlert: { _ in .alertSecondButtonReturn }
        )

        notifier.notifyManualPasteRequired()

        XCTAssertTrue(openedURLs.isEmpty)
    }

    func testSetupPermissionRequestUsesSystemAuthorizationPathWithoutAnExtraSuccessDialog() {
        var requestCount = 0
        var displayedAlerts: [NSAlert] = []
        let notifier = SystemAutoPasteNotifier(
            runAlert: {
                displayedAlerts.append($0)
                return .alertFirstButtonReturn
            },
            requestAuthorization: { completion in
                requestCount += 1
                completion(true)
            }
        )

        notifier.requestPermissionFromSetup()

        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(displayedAlerts.isEmpty)
    }

    func testSetupDoesNotShowAppAlertUntilSystemPermissionDialogFinishesWithDenial() {
        var finishSystemRequest: ((Bool) -> Void)?
        var displayedAlerts: [NSAlert] = []
        let notifier = SystemAutoPasteNotifier(
            runAlert: {
                displayedAlerts.append($0)
                return .alertSecondButtonReturn
            },
            requestAuthorization: { finishSystemRequest = $0 }
        )

        notifier.requestPermissionFromSetup()

        XCTAssertTrue(displayedAlerts.isEmpty)
        finishSystemRequest?(false)
        XCTAssertEqual(displayedAlerts.count, 1)
        XCTAssertEqual(
            displayedAlerts.first?.messageText,
            L10n.string("autopaste.permission-required-title")
        )
    }

    func testSetupDoesNotShowAppAlertAfterSystemPermissionDialogGrantsAccess() {
        var finishSystemRequest: ((Bool) -> Void)?
        var displayedAlerts: [NSAlert] = []
        let notifier = SystemAutoPasteNotifier(
            runAlert: {
                displayedAlerts.append($0)
                return .alertFirstButtonReturn
            },
            requestAuthorization: { finishSystemRequest = $0 }
        )

        notifier.requestPermissionFromSetup()
        XCTAssertTrue(displayedAlerts.isEmpty)

        finishSystemRequest?(true)

        XCTAssertTrue(displayedAlerts.isEmpty)
    }

    func testSystemAuthorizationPollsPreflightOftenEnoughToDetectGrantWithinThreeSeconds() {
        var scheduledRecheck: (@MainActor () -> Void)?
        var scheduledInterval: TimeInterval?
        var isAuthorized = false
        var authorizationResult: Bool?
        let authorization = SystemPasteEventAuthorization(
            preflightAccess: { isAuthorized },
            requestSystemAccess: { false },
            scheduleRecheck: { interval, recheck in
                scheduledInterval = interval
                scheduledRecheck = recheck
            },
            isApplicationActive: { false }
        )

        authorization.requestAccess { authorizationResult = $0 }
        XCTAssertNil(authorizationResult)
        XCTAssertNotNil(scheduledRecheck)
        XCTAssertEqual(scheduledInterval, 0.5)

        isAuthorized = true
        scheduledRecheck?()

        XCTAssertEqual(authorizationResult, true)
    }

    func testSystemAuthorizationCompletesEveryRequestThatArrivesWhilePolling() {
        var scheduledRecheck: (@MainActor () -> Void)?
        var isAuthorized = false
        var authorizationResults: [Bool] = []
        let authorization = SystemPasteEventAuthorization(
            preflightAccess: { isAuthorized },
            requestSystemAccess: { false },
            scheduleRecheck: { _, recheck in scheduledRecheck = recheck },
            isApplicationActive: { false }
        )

        authorization.requestAccess { authorizationResults.append($0) }
        authorization.requestAccess { authorizationResults.append($0) }
        XCTAssertTrue(authorizationResults.isEmpty)

        isAuthorized = true
        scheduledRecheck?()

        XCTAssertEqual(authorizationResults, [true, true])
    }

    func testSystemAuthorizationCompletesWhenSystemDoesNotShowPermissionDialog() {
        var scheduledRecheck: (@MainActor () -> Void)?
        var authorizationResult: Bool?
        let authorization = SystemPasteEventAuthorization(
            preflightAccess: { false },
            requestSystemAccess: { false },
            scheduleRecheck: { _, recheck in scheduledRecheck = recheck },
            isApplicationActive: { true }
        )

        authorization.requestAccess { authorizationResult = $0 }
        scheduledRecheck?()

        XCTAssertEqual(authorizationResult, false)
    }

    func testSystemAuthorizationKeepsPollingWithoutCompletingWhileSystemDialogHasFocus() {
        var scheduledRechecks: [(@MainActor () -> Void)] = []
        var authorizationResult: Bool?
        let authorization = SystemPasteEventAuthorization(
            preflightAccess: { false },
            requestSystemAccess: { false },
            scheduleRecheck: { _, recheck in scheduledRechecks.append(recheck) },
            isApplicationActive: { false }
        )

        authorization.requestAccess { authorizationResult = $0 }
        XCTAssertEqual(scheduledRechecks.count, 1)
        scheduledRechecks.removeFirst()()

        XCTAssertNil(
            authorizationResult,
            "OSの権限ダイアログが出ている間に権限要求を打ち切ると、アプリの案内が重なって表示される"
        )
        XCTAssertEqual(scheduledRechecks.count, 1, "Polling must continue until the system dialog closes")
    }

    func testSystemAuthorizationCompletesAllPendingDenialsWhenDialogClosesWhileAppStaysInactive() {
        let workspaceNotificationCenter = NotificationCenter()
        var scheduledRechecks: [(@MainActor () -> Void)] = []
        var authorizationResults: [Bool] = []
        let previousApplication = NSRunningApplication.current
        let authorization = SystemPasteEventAuthorization(
            preflightAccess: { false },
            requestSystemAccess: { false },
            scheduleRecheck: { _, recheck in scheduledRechecks.append(recheck) },
            isApplicationActive: { false },
            frontmostApplicationProcessIdentifier: { previousApplication.processIdentifier },
            workspaceNotificationCenter: workspaceNotificationCenter
        )

        authorization.requestAccess { authorizationResults.append($0) }
        scheduledRechecks.removeFirst()()

        XCTAssertTrue(
            authorizationResults.isEmpty,
            "The app-side permission notice must not appear over the system dialog"
        )

        authorization.requestAccess { authorizationResults.append($0) }
        workspaceNotificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: previousApplication]
        )

        XCTAssertEqual(authorizationResults, [false, false])
    }

    func testSystemAuthorizationObservesDismissalBeforeRequestCanEmitNotification() {
        let workspaceNotificationCenter = NotificationCenter()
        let previousApplication = NSRunningApplication.current
        var scheduledRechecks: [(@MainActor () -> Void)] = []
        var authorizationResults: [Bool] = []
        let authorization = SystemPasteEventAuthorization(
            preflightAccess: { false },
            requestSystemAccess: {
                workspaceNotificationCenter.post(
                    name: NSWorkspace.didActivateApplicationNotification,
                    object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: previousApplication]
                )
                return false
            },
            scheduleRecheck: { _, recheck in scheduledRechecks.append(recheck) },
            isApplicationActive: { false },
            frontmostApplicationProcessIdentifier: { previousApplication.processIdentifier },
            workspaceNotificationCenter: workspaceNotificationCenter
        )

        authorization.requestAccess { authorizationResults.append($0) }

        XCTAssertEqual(authorizationResults, [false])
        XCTAssertEqual(scheduledRechecks.count, 1)
        scheduledRechecks.removeFirst()()
        XCTAssertEqual(authorizationResults, [false], "A stale scheduled poll must not complete twice")
    }

    func testSystemAuthorizationIgnoresUnrelatedActivationWhileDialogIsVisible() {
        let workspaceNotificationCenter = NotificationCenter()
        let unrelatedApplication = NSRunningApplication.current
        var isApplicationActive = false
        var authorizationResults: [Bool] = []
        let authorization = SystemPasteEventAuthorization(
            preflightAccess: { false },
            requestSystemAccess: { false },
            scheduleRecheck: { _, _ in },
            isApplicationActive: { isApplicationActive },
            frontmostApplicationProcessIdentifier: {
                unrelatedApplication.processIdentifier &+ 1
            },
            workspaceNotificationCenter: workspaceNotificationCenter
        )

        authorization.requestAccess { authorizationResults.append($0) }
        authorization.requestAccess { authorizationResults.append($0) }
        workspaceNotificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: unrelatedApplication]
        )

        XCTAssertTrue(authorizationResults.isEmpty)

        isApplicationActive = true
        workspaceNotificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: unrelatedApplication]
        )
        XCTAssertEqual(authorizationResults, [false, false])
    }

    func testSystemAuthorizationDoesNotTreatAnUnidentifiedActivationAsDismissal() {
        let workspaceNotificationCenter = NotificationCenter()
        var authorizationResult: Bool?
        let authorization = SystemPasteEventAuthorization(
            preflightAccess: { false },
            requestSystemAccess: { false },
            scheduleRecheck: { _, _ in },
            isApplicationActive: { false },
            frontmostApplicationProcessIdentifier: { nil },
            workspaceNotificationCenter: workspaceNotificationCenter
        )

        authorization.requestAccess { authorizationResult = $0 }
        workspaceNotificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        XCTAssertNil(authorizationResult)
    }

    func testReturningFromSettingsRechecksPermissionAndShowsThatAutoPasteIsReady() {
        var scheduledRecheck: (@MainActor () -> Void)?
        var authorizationChecks = 0
        var displayedAlerts: [NSAlert] = []
        let notifier = SystemAutoPasteNotifier(
            openURL: { _ in true },
            runAlert: {
                displayedAlerts.append($0)
                return displayedAlerts.count == 1 ? .alertFirstButtonReturn : .alertSecondButtonReturn
            },
            isAuthorized: {
                authorizationChecks += 1
                return true
            },
            schedulePermissionRecheck: { _, recheck in scheduledRecheck = recheck }
        )

        notifier.notifyManualPasteRequired()
        scheduledRecheck?()

        XCTAssertEqual(authorizationChecks, 1)
        XCTAssertEqual(displayedAlerts.count, 2)
        XCTAssertEqual(
            displayedAlerts.last?.messageText,
            L10n.string("autopaste.permission-enabled-title")
        )
        XCTAssertEqual(
            displayedAlerts.last?.informativeText,
            L10n.string("autopaste.permission-enabled-message")
        )

        scheduledRecheck?()
        XCTAssertEqual(authorizationChecks, 1, "Permission should be checked once per trip to Settings")
    }

    func testSettingsPermissionIsPolledAndDetectedWithoutApplicationActivation() {
        var scheduledRechecks: [(@MainActor () -> Void)] = []
        var scheduledIntervals: [TimeInterval] = []
        var isAuthorized = false
        var displayedAlerts: [NSAlert] = []
        let notifier = SystemAutoPasteNotifier(
            openURL: { _ in true },
            runAlert: {
                displayedAlerts.append($0)
                return displayedAlerts.count == 1 ? .alertFirstButtonReturn : .alertSecondButtonReturn
            },
            isAuthorized: { isAuthorized },
            schedulePermissionRecheck: { interval, recheck in
                scheduledIntervals.append(interval)
                scheduledRechecks.append(recheck)
            }
        )

        notifier.notifyManualPasteRequired()
        XCTAssertEqual(scheduledRechecks.count, 1)
        XCTAssertEqual(scheduledIntervals[0], 0.5)

        scheduledRechecks.removeFirst()()
        XCTAssertEqual(displayedAlerts.count, 1, "No app modal may cover the system UI while access is pending")
        XCTAssertEqual(scheduledRechecks.count, 1)

        isAuthorized = true
        scheduledRechecks.removeFirst()()

        XCTAssertEqual(displayedAlerts.count, 2)
        XCTAssertEqual(
            displayedAlerts.last?.messageText,
            L10n.string("autopaste.permission-enabled-title")
        )
    }

    func testRestartButtonRelaunchesApplicationAndTerminatesCurrentInstance() {
        let suiteName = "AutoPasteTests.restart.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var scheduledRecheck: (@MainActor () -> Void)?
        let applicationURL = URL(fileURLWithPath: "/Applications/Snapspool.app")
        var relaunchedURLs: [URL] = []
        var terminationCount = 0
        var relaunchSequence: [String] = []
        var displayedAlerts: [NSAlert] = []
        let notifier = SystemAutoPasteNotifier(
            openURL: { _ in true },
            runAlert: {
                displayedAlerts.append($0)
                return .alertFirstButtonReturn
            },
            isAuthorized: { false },
            isApplicationActive: { true },
            schedulePermissionRecheck: { _, recheck in scheduledRecheck = recheck },
            defaults: defaults,
            applicationURL: applicationURL,
            prepareForRelaunch: { relaunchSequence.append("unregister") },
            relaunchApplication: { url in
                relaunchSequence.append("launch")
                relaunchedURLs.append(url)
                return true
            },
            recoverFromFailedRelaunch: { relaunchSequence.append("recover") },
            terminateCurrentApplication: {
                relaunchSequence.append("terminate")
                terminationCount += 1
            }
        )

        notifier.notifyManualPasteRequired()
        scheduledRecheck?()

        XCTAssertEqual(displayedAlerts.count, 2)
        XCTAssertEqual(
            displayedAlerts.last?.buttons.map(\.title),
            [L10n.string("autopaste.restart"), L10n.string("autopaste.not-now")]
        )
        XCTAssertEqual(
            displayedAlerts.last?.informativeText,
            L10n.string("autopaste.permission-not-active-message")
        )
        XCTAssertEqual(relaunchedURLs, [applicationURL])
        XCTAssertEqual(terminationCount, 1)
        XCTAssertEqual(relaunchSequence, ["unregister", "launch", "terminate"])
    }

    func testNotNowKeepsCurrentHistoryByLeavingApplicationRunning() {
        var scheduledRecheck: (@MainActor () -> Void)?
        var displayedAlerts: [NSAlert] = []
        var relaunchSequence: [String] = []
        let notifier = SystemAutoPasteNotifier(
            openURL: { _ in true },
            runAlert: {
                displayedAlerts.append($0)
                return displayedAlerts.count == 1
                    ? .alertFirstButtonReturn
                    : .alertSecondButtonReturn
            },
            isAuthorized: { false },
            isApplicationActive: { true },
            schedulePermissionRecheck: { _, recheck in scheduledRecheck = recheck },
            prepareForRelaunch: { relaunchSequence.append("unregister") },
            relaunchApplication: { _ in
                relaunchSequence.append("launch")
                return true
            },
            recoverFromFailedRelaunch: { relaunchSequence.append("recover") },
            terminateCurrentApplication: { relaunchSequence.append("terminate") }
        )

        notifier.notifyManualPasteRequired()
        scheduledRecheck?()

        XCTAssertEqual(displayedAlerts.count, 2)
        XCTAssertEqual(
            displayedAlerts.last?.informativeText,
            L10n.string("autopaste.permission-not-active-message")
        )
        XCTAssertTrue(
            relaunchSequence.isEmpty,
            "Choosing Not Now must keep the process and its in-memory history alive"
        )
    }

    func testRelaunchedInstanceRechecksPermissionAndShowsThatAutoPasteIsReady() {
        let suiteName = "AutoPasteTests.permissionRelaunch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var scheduledRecheck: (@MainActor () -> Void)?
        var terminationCount = 0
        var oldInstanceAlerts: [NSAlert] = []
        let oldInstance = SystemAutoPasteNotifier(
            openURL: { _ in true },
            runAlert: {
                oldInstanceAlerts.append($0)
                return .alertFirstButtonReturn
            },
            isAuthorized: { false },
            isApplicationActive: { true },
            schedulePermissionRecheck: { _, recheck in scheduledRecheck = recheck },
            defaults: defaults,
            relaunchApplication: { _ in true },
            terminateCurrentApplication: { terminationCount += 1 }
        )

        oldInstance.notifyManualPasteRequired()
        scheduledRecheck?()

        var authorizationChecks = 0
        var newInstanceAlerts: [NSAlert] = []
        _ = SystemAutoPasteNotifier(
            runAlert: {
                newInstanceAlerts.append($0)
                return .alertFirstButtonReturn
            },
            isAuthorized: {
                authorizationChecks += 1
                return true
            },
            defaults: defaults
        )

        XCTAssertEqual(terminationCount, 1)
        XCTAssertEqual(authorizationChecks, 1)
        XCTAssertEqual(newInstanceAlerts.count, 1)
        XCTAssertEqual(
            newInstanceAlerts.first?.messageText,
            L10n.string("autopaste.permission-enabled-title")
        )
        XCTAssertEqual(
            newInstanceAlerts.first?.informativeText,
            L10n.string("autopaste.permission-enabled-message")
        )

        var laterAuthorizationChecks = 0
        _ = SystemAutoPasteNotifier(
            runAlert: { _ in XCTFail("The consumed relaunch state must not show another alert"); return .abort },
            isAuthorized: {
                laterAuthorizationChecks += 1
                return true
            },
            defaults: defaults
        )
        XCTAssertEqual(laterAuthorizationChecks, 0)
    }

    func testFailedAutomaticRestartShowsManualFallbackWithoutTerminating() {
        let suiteName = "AutoPasteTests.failedRestart.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var scheduledRecheck: (@MainActor () -> Void)?
        var displayedAlerts: [NSAlert] = []
        var terminationCount = 0
        var relaunchSequence: [String] = []
        let notifier = SystemAutoPasteNotifier(
            openURL: { _ in true },
            runAlert: {
                displayedAlerts.append($0)
                return .alertFirstButtonReturn
            },
            isAuthorized: { false },
            isApplicationActive: { true },
            schedulePermissionRecheck: { _, recheck in scheduledRecheck = recheck },
            defaults: defaults,
            prepareForRelaunch: { relaunchSequence.append("unregister") },
            relaunchApplication: { _ in
                relaunchSequence.append("launch")
                return false
            },
            recoverFromFailedRelaunch: { relaunchSequence.append("recover") },
            terminateCurrentApplication: { terminationCount += 1 }
        )

        notifier.notifyManualPasteRequired()
        scheduledRecheck?()

        XCTAssertEqual(displayedAlerts.count, 3)
        XCTAssertEqual(
            displayedAlerts.last?.messageText,
            L10n.string("autopaste.restart-failed-title")
        )
        XCTAssertEqual(
            displayedAlerts.last?.informativeText,
            L10n.string("autopaste.restart-failed-message")
        )
        XCTAssertEqual(terminationCount, 0)
        XCTAssertEqual(relaunchSequence, ["unregister", "launch", "recover"])
    }

    func testRelaunchReleasesOldRegistrationBeforeNewInstanceUsesConfiguredShortcut() {
        let suiteName = "AutoPasteTests.hotKeyHandoff.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var scheduledRecheck: (@MainActor () -> Void)?
        let shortcut = GlobalShortcut(
            keyCode: UInt32(kVK_ANSI_B),
            modifiers: UInt32(controlKey)
        )
        let sharedRegistration = ExclusiveHotKeyRegistration()
        var oldPickerCount = 0
        let oldController = GlobalHotKeyController(
            registrar: ExclusiveHotKeyRegistrar(registration: sharedRegistration),
            configuredShortcut: shortcut,
            showHistoryPicker: { oldPickerCount += 1 }
        )
        XCTAssertTrue(oldController.start())

        var newController: GlobalHotKeyController?
        var newPickerCount = 0
        var terminationCount = 0
        let notifier = SystemAutoPasteNotifier(
            openURL: { _ in true },
            runAlert: { _ in .alertFirstButtonReturn },
            isAuthorized: { false },
            isApplicationActive: { true },
            schedulePermissionRecheck: { _, recheck in scheduledRecheck = recheck },
            defaults: defaults,
            prepareForRelaunch: { oldController.stop() },
            relaunchApplication: { _ in
                let controller = GlobalHotKeyController(
                    registrar: ExclusiveHotKeyRegistrar(registration: sharedRegistration),
                    configuredShortcut: shortcut,
                    showHistoryPicker: { newPickerCount += 1 }
                )
                guard controller.start() else { return false }
                newController = controller
                return true
            },
            recoverFromFailedRelaunch: { _ = oldController.start() },
            terminateCurrentApplication: { terminationCount += 1 }
        )

        notifier.notifyManualPasteRequired()
        scheduledRecheck?()

        XCTAssertNotNil(newController)
        XCTAssertEqual(sharedRegistration.registeredShortcut, shortcut)
        sharedRegistration.invokeHandler()
        XCTAssertEqual(newPickerCount, 1)
        XCTAssertEqual(oldPickerCount, 0)
        XCTAssertEqual(terminationCount, 1)
    }

    func testSystemTargetProviderRejectsSnapspoolItself() {
        let log = AutoPasteCallLog()
        let application = LoggedTargetApplication(
            name: "Snapspool",
            processIdentifier: 42,
            log: log
        )
        let provider = SystemPasteTargetApplicationProvider(
            frontmostApplication: { application },
            currentProcessIdentifier: { 42 }
        )

        XCTAssertNil(provider.frontmostApplication())
    }

    func testAuthorizedAutoPasteSendsCommandVWithoutFallbackNotice() {
        let log = AutoPasteCallLog()
        let controller = makeController(log: log, isAuthorized: true)

        controller.captureTargetApplication()
        controller.pasteIfEnabled(true)

        XCTAssertEqual(log.calls, ["authorize", "activate:target", "send"])
    }

    func testHistorySelectionRestoresClipboardThenReactivatesCapturedApplicationBeforeSendingPaste() throws {
        let log = AutoPasteCallLog()
        let pasteboard = LoggedPasteboard(log: log)
        let originalTarget = LoggedTargetApplication(name: "original", log: log)
        let laterFrontmostApplication = LoggedTargetApplication(name: "later", log: log)
        let provider = LoggedTargetApplicationProvider(
            application: originalTarget,
            onCapture: { log.calls.append("capture:original") }
        )
        let autoPasteController = makeController(
            log: log,
            isAuthorized: true,
            targetApplicationProvider: provider
        )
        let handler = HistorySelectionHandler(
            restorer: ClipboardRestorer(pasteboard: pasteboard),
            autoPasteController: autoPasteController,
            isAutoPasteEnabled: { true }
        )
        let entry = HistoryEntry(
            content: .text(Data("chosen history".utf8)),
            detectionOrder: 0
        )

        autoPasteController.captureTargetApplication()
        provider.application = laterFrontmostApplication
        try handler.confirm(entry)

        XCTAssertEqual(
            log.calls,
            ["capture:original", "restore", "authorize", "activate:original", "send"]
        )
        XCTAssertEqual(
            pasteboard.dataByType[ClipboardContentSelector.plainTextType],
            Data("chosen history".utf8)
        )
    }

    func testFailedRestorationDoesNotRequestPermissionOrSendPaste() {
        let log = AutoPasteCallLog()
        let handler = HistorySelectionHandler(
            restorer: ClipboardRestorer(pasteboard: FailingLoggedPasteboard(log: log)),
            autoPasteController: makeController(log: log, isAuthorized: true),
            isAutoPasteEnabled: { true }
        )
        let entry = HistoryEntry(
            content: .text(Data("not restored".utf8)),
            detectionOrder: 0
        )

        XCTAssertThrowsError(try handler.confirm(entry))
        XCTAssertEqual(log.calls, ["restore"])
    }

    func testSystemSenderBuildsCommandVKeyDownAndKeyUpEvents() throws {
        var events: [CGEvent] = []
        let sender = SystemPasteEventSender { events.append($0.copy()!) }

        XCTAssertTrue(sender.sendPasteShortcut())
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
        XCTAssertEqual(
            events.map { $0.getIntegerValueField(.keyboardEventKeycode) },
            [9, 9]
        )
        XCTAssertEqual(events.map(\.flags), [.maskCommand, .maskCommand])
    }

    private func makeController(
        log: AutoPasteCallLog,
        isAuthorized: Bool,
        targetApplicationProvider: (any PasteTargetApplicationProviding)? = nil
    ) -> AutoPasteController {
        AutoPasteController(
            authorization: LoggedAuthorization(log: log, result: isAuthorized),
            eventSender: LoggedEventSender(log: log),
            notifier: LoggedAutoPasteNotifier(log: log),
            targetApplicationProvider: targetApplicationProvider
                ?? LoggedTargetApplicationProvider(
                    application: LoggedTargetApplication(name: "target", log: log)
                )
        )
    }
}

@MainActor
private final class AutoPasteCallLog {
    var calls: [String] = []
}

@MainActor
private struct LoggedAuthorization: PasteEventAuthorizing {
    let log: AutoPasteCallLog
    let result: Bool

    func requestAccess(completion: @escaping (Bool) -> Void) {
        log.calls.append("authorize")
        completion(result)
    }
}

@MainActor
private final class DeferredAuthorization: PasteEventAuthorizing {
    private let log: AutoPasteCallLog
    private var completion: ((Bool) -> Void)?

    init(log: AutoPasteCallLog) {
        self.log = log
    }

    func requestAccess(completion: @escaping (Bool) -> Void) {
        log.calls.append("authorize")
        self.completion = completion
    }

    func finish(isAuthorized: Bool) {
        let pendingCompletion = completion
        completion = nil
        pendingCompletion?(isAuthorized)
    }
}

@MainActor
private struct LoggedEventSender: PasteEventSending {
    let log: AutoPasteCallLog

    func sendPasteShortcut() -> Bool {
        log.calls.append("send")
        return true
    }
}

@MainActor
private struct LoggedAutoPasteNotifier: AutoPasteNotifying {
    let log: AutoPasteCallLog

    func notifyManualPasteRequired() {
        log.calls.append("notify")
    }
}

@MainActor
private final class LoggedTargetApplication: PasteTargetApplication {
    let processIdentifier: pid_t
    private let name: String
    private let log: AutoPasteCallLog

    init(name: String, processIdentifier: pid_t = 12_345, log: AutoPasteCallLog) {
        self.name = name
        self.processIdentifier = processIdentifier
        self.log = log
    }

    func activateForPaste() -> Bool {
        log.calls.append("activate:\(name)")
        return true
    }
}

@MainActor
private final class LoggedTargetApplicationProvider: PasteTargetApplicationProviding {
    var application: (any PasteTargetApplication)?
    private let onCapture: () -> Void

    init(application: (any PasteTargetApplication)?, onCapture: @escaping () -> Void = {}) {
        self.application = application
        self.onCapture = onCapture
    }

    func frontmostApplication() -> (any PasteTargetApplication)? {
        onCapture()
        return application
    }
}

@MainActor
private final class LoggedPasteboard: ClipboardPasteboardWriting {
    private let log: AutoPasteCallLog
    private(set) var dataByType: [NSPasteboard.PasteboardType: Data] = [:]

    init(log: AutoPasteCallLog) {
        self.log = log
    }

    func replaceContents(with representations: [PasteboardRepresentation]) -> Bool {
        log.calls.append("restore")
        dataByType = Dictionary(uniqueKeysWithValues: representations.map { ($0.type, $0.data) })
        return true
    }
}

@MainActor
private final class FailingLoggedPasteboard: ClipboardPasteboardWriting {
    private let log: AutoPasteCallLog

    init(log: AutoPasteCallLog) {
        self.log = log
    }

    func replaceContents(with representations: [PasteboardRepresentation]) -> Bool {
        log.calls.append("restore")
        return false
    }
}

@MainActor
private final class ExclusiveHotKeyRegistration {
    private(set) var registeredShortcut: GlobalShortcut?
    private var owner: ObjectIdentifier?
    private var handler: (@MainActor @Sendable () -> Void)?

    func register(
        owner candidateOwner: ObjectIdentifier,
        shortcut: GlobalShortcut,
        handler: @MainActor @Sendable @escaping () -> Void
    ) -> Bool {
        guard owner == nil || owner == candidateOwner else { return false }
        owner = candidateOwner
        registeredShortcut = shortcut
        self.handler = handler
        return true
    }

    func unregister(owner candidateOwner: ObjectIdentifier) {
        guard owner == candidateOwner else { return }
        owner = nil
        registeredShortcut = nil
        handler = nil
    }

    func invokeHandler() {
        handler?()
    }
}

@MainActor
private final class ExclusiveHotKeyRegistrar: GlobalHotKeyRegistering {
    private let registration: ExclusiveHotKeyRegistration

    init(registration: ExclusiveHotKeyRegistration) {
        self.registration = registration
    }

    func register(
        _ shortcut: GlobalShortcut,
        handler: @MainActor @Sendable @escaping () -> Void
    ) -> Bool {
        registration.register(
            owner: ObjectIdentifier(self),
            shortcut: shortcut,
            handler: handler
        )
    }

    func unregister() {
        registration.unregister(owner: ObjectIdentifier(self))
    }
}
