import AppKit
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

    func testReturningFromSettingsRechecksPermissionAndShowsThatAutoPasteIsReady() {
        let notificationCenter = NotificationCenter()
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
            notificationCenter: notificationCenter
        )

        notifier.notifyManualPasteRequired()
        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)

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

        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(authorizationChecks, 1, "Permission should be checked once per trip to Settings")
    }

    func testRestartButtonRelaunchesApplicationAndTerminatesCurrentInstance() {
        let suiteName = "AutoPasteTests.restart.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notificationCenter = NotificationCenter()
        let applicationURL = URL(fileURLWithPath: "/Applications/Snapspool.app")
        var relaunchedURLs: [URL] = []
        var terminationCount = 0
        var displayedAlerts: [NSAlert] = []
        let notifier = SystemAutoPasteNotifier(
            openURL: { _ in true },
            runAlert: {
                displayedAlerts.append($0)
                return .alertFirstButtonReturn
            },
            isAuthorized: { false },
            notificationCenter: notificationCenter,
            defaults: defaults,
            applicationURL: applicationURL,
            relaunchApplication: {
                relaunchedURLs.append($0)
                return true
            },
            terminateCurrentApplication: { terminationCount += 1 }
        )

        notifier.notifyManualPasteRequired()
        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        XCTAssertEqual(displayedAlerts.count, 2)
        XCTAssertEqual(
            displayedAlerts.last?.buttons.map(\.title),
            [L10n.string("autopaste.restart"), L10n.string("autopaste.not-now")]
        )
        XCTAssertEqual(relaunchedURLs, [applicationURL])
        XCTAssertEqual(terminationCount, 1)
    }

    func testRelaunchedInstanceRechecksPermissionAndShowsThatAutoPasteIsReady() {
        let suiteName = "AutoPasteTests.permissionRelaunch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notificationCenter = NotificationCenter()
        var terminationCount = 0
        var oldInstanceAlerts: [NSAlert] = []
        let oldInstance = SystemAutoPasteNotifier(
            openURL: { _ in true },
            runAlert: {
                oldInstanceAlerts.append($0)
                return .alertFirstButtonReturn
            },
            isAuthorized: { false },
            notificationCenter: notificationCenter,
            defaults: defaults,
            relaunchApplication: { _ in true },
            terminateCurrentApplication: { terminationCount += 1 }
        )

        oldInstance.notifyManualPasteRequired()
        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)

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
            notificationCenter: NotificationCenter(),
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
            notificationCenter: NotificationCenter(),
            defaults: defaults
        )
        XCTAssertEqual(laterAuthorizationChecks, 0)
    }

    func testFailedAutomaticRestartShowsManualFallbackWithoutTerminating() {
        let suiteName = "AutoPasteTests.failedRestart.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notificationCenter = NotificationCenter()
        var displayedAlerts: [NSAlert] = []
        var terminationCount = 0
        let notifier = SystemAutoPasteNotifier(
            openURL: { _ in true },
            runAlert: {
                displayedAlerts.append($0)
                return .alertFirstButtonReturn
            },
            isAuthorized: { false },
            notificationCenter: notificationCenter,
            defaults: defaults,
            relaunchApplication: { _ in false },
            terminateCurrentApplication: { terminationCount += 1 }
        )

        notifier.notifyManualPasteRequired()
        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)

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

    func requestAccess() -> Bool {
        log.calls.append("authorize")
        return result
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
