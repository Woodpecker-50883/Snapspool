import AppKit
import Carbon.HIToolbox
import CoreGraphics

@MainActor
protocol PasteEventAuthorizing {
    func requestAccess() -> Bool
}

@MainActor
struct SystemPasteEventAuthorization: PasteEventAuthorizing {
    func requestAccess() -> Bool {
        CGPreflightPostEventAccess() || CGRequestPostEventAccess()
    }
}

@MainActor
protocol PasteEventSending {
    func sendPasteShortcut() -> Bool
}

@MainActor
protocol PasteTargetApplication: AnyObject {
    var processIdentifier: pid_t { get }
    func activateForPaste() -> Bool
}

@MainActor
extension NSRunningApplication: PasteTargetApplication {
    func activateForPaste() -> Bool {
        activate(options: [.activateAllWindows])
    }
}

@MainActor
protocol PasteTargetApplicationProviding {
    func frontmostApplication() -> (any PasteTargetApplication)?
}

@MainActor
struct SystemPasteTargetApplicationProvider: PasteTargetApplicationProviding {
    private let frontmostApplicationLookup: () -> (any PasteTargetApplication)?
    private let currentProcessIdentifier: () -> pid_t

    init(
        frontmostApplication: @escaping () -> (any PasteTargetApplication)? = {
            NSWorkspace.shared.frontmostApplication
        },
        currentProcessIdentifier: @escaping () -> pid_t = {
            NSRunningApplication.current.processIdentifier
        }
    ) {
        frontmostApplicationLookup = frontmostApplication
        self.currentProcessIdentifier = currentProcessIdentifier
    }

    func frontmostApplication() -> (any PasteTargetApplication)? {
        guard let application = frontmostApplicationLookup(),
              application.processIdentifier != currentProcessIdentifier() else {
            return nil
        }
        return application
    }
}

@MainActor
struct SystemPasteEventSender: PasteEventSending {
    private let postEvent: (CGEvent) -> Void

    init(postEvent: @escaping (CGEvent) -> Void = { event in
        event.post(tap: .cgSessionEventTap)
    }) {
        self.postEvent = postEvent
    }

    func sendPasteShortcut() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(kVK_ANSI_V),
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(kVK_ANSI_V),
                  keyDown: false
              ) else { return false }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        postEvent(keyDown)
        postEvent(keyUp)
        return true
    }
}

@MainActor
protocol AutoPasteNotifying {
    func notifyManualPasteRequired()
}

@MainActor
protocol AutoPastePermissionGuiding: AnyObject {
    func requestPermissionFromSetup()
}

@MainActor
final class SystemAutoPasteNotifier: NSObject, AutoPasteNotifying, AutoPastePermissionGuiding {
    private static let pendingPermissionCheckKey =
        "autopaste.pendingPermissionCheckAfterRelaunch"

    static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!

    private let openURL: (URL) -> Bool
    private let runAlert: (NSAlert) -> NSApplication.ModalResponse
    private let requestAuthorization: () -> Bool
    private let isAuthorized: () -> Bool
    private let notificationCenter: NotificationCenter
    private let defaults: UserDefaults
    private let applicationURL: URL
    private let prepareForRelaunch: () -> Void
    private let relaunchApplication: (URL) -> Bool
    private let recoverFromFailedRelaunch: () -> Void
    private let terminateCurrentApplication: () -> Void
    private var isWaitingForSettingsReturn = false

    init(
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        runAlert: @escaping (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() },
        requestAuthorization: @escaping () -> Bool = {
            CGPreflightPostEventAccess() || CGRequestPostEventAccess()
        },
        isAuthorized: @escaping () -> Bool = { CGPreflightPostEventAccess() },
        notificationCenter: NotificationCenter = .default,
        defaults: UserDefaults = .standard,
        applicationURL: URL = Bundle.main.bundleURL,
        prepareForRelaunch: @escaping () -> Void = {},
        relaunchApplication: @escaping (URL) -> Bool = { applicationURL in
            (try? NSWorkspace.shared.launchApplication(
                at: applicationURL,
                options: [.newInstance],
                configuration: [:]
            )) != nil
        },
        recoverFromFailedRelaunch: @escaping () -> Void = {},
        terminateCurrentApplication: @escaping () -> Void = {
            NSApplication.shared.terminate(nil)
        }
    ) {
        self.openURL = openURL
        self.runAlert = runAlert
        self.requestAuthorization = requestAuthorization
        self.isAuthorized = isAuthorized
        self.notificationCenter = notificationCenter
        self.defaults = defaults
        self.applicationURL = applicationURL
        self.prepareForRelaunch = prepareForRelaunch
        self.relaunchApplication = relaunchApplication
        self.recoverFromFailedRelaunch = recoverFromFailedRelaunch
        self.terminateCurrentApplication = terminateCurrentApplication
        super.init()
        checkPermissionAfterRelaunchIfNeeded()
    }

    deinit {
        notificationCenter.removeObserver(self)
    }

    func notifyManualPasteRequired() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.string("autopaste.permission-required-title")
        alert.informativeText = L10n.string("autopaste.permission-required-message")
        alert.addButton(withTitle: L10n.string("autopaste.open-accessibility-settings"))
        alert.addButton(withTitle: L10n.string("common.ok"))
        if runAlert(alert) == .alertFirstButtonReturn {
            startWaitingForSettingsReturn()
            if !openURL(Self.accessibilitySettingsURL) {
                stopWaitingForSettingsReturn()
            }
        }
    }

    func requestPermissionFromSetup() {
        if requestAuthorization() {
            showPermissionEnabledAlert()
        } else {
            notifyManualPasteRequired()
        }
    }

    private func startWaitingForSettingsReturn() {
        guard !isWaitingForSettingsReturn else { return }
        isWaitingForSettingsReturn = true
        notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    private func stopWaitingForSettingsReturn() {
        isWaitingForSettingsReturn = false
        notificationCenter.removeObserver(
            self,
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func applicationDidBecomeActive() {
        guard isWaitingForSettingsReturn else { return }
        stopWaitingForSettingsReturn()

        if isAuthorized() {
            showPermissionEnabledAlert()
        } else {
            showRestartOffer()
        }
    }

    private func showPermissionEnabledAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.string("autopaste.permission-enabled-title")
        alert.informativeText = L10n.string("autopaste.permission-enabled-message")
        alert.addButton(withTitle: L10n.string("common.ok"))
        _ = runAlert(alert)
    }

    private func showRestartOffer() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.string("autopaste.permission-not-active-title")
        alert.informativeText = L10n.string("autopaste.permission-not-active-message")
        alert.addButton(withTitle: L10n.string("autopaste.restart"))
        alert.addButton(withTitle: L10n.string("autopaste.not-now"))
        guard runAlert(alert) == .alertFirstButtonReturn else { return }

        defaults.set(true, forKey: Self.pendingPermissionCheckKey)
        // Make the hand-off visible to the newly launched process before it
        // starts reading its defaults domain.
        defaults.synchronize()

        // Carbon rejects a duplicate shortcut while the old process still
        // owns it. Release that registration before starting the replacement
        // process, and restore it if the launch itself fails.
        prepareForRelaunch()
        if relaunchApplication(applicationURL) {
            terminateCurrentApplication()
        } else {
            recoverFromFailedRelaunch()
            defaults.removeObject(forKey: Self.pendingPermissionCheckKey)
            showManualRestartAlert()
        }
    }

    private func checkPermissionAfterRelaunchIfNeeded() {
        guard defaults.bool(forKey: Self.pendingPermissionCheckKey) else { return }

        // Consume the hand-off even when access is still unavailable so an
        // ordinary later launch does not repeatedly display a stale result.
        defaults.removeObject(forKey: Self.pendingPermissionCheckKey)
        guard isAuthorized() else { return }
        showPermissionEnabledAlert()
    }

    private func showManualRestartAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("autopaste.restart-failed-title")
        alert.informativeText = L10n.string("autopaste.restart-failed-message")
        alert.addButton(withTitle: L10n.string("common.ok"))
        _ = runAlert(alert)
    }
}

@MainActor
final class AutoPasteController {
    private let authorization: any PasteEventAuthorizing
    private let eventSender: any PasteEventSending
    private let notifier: any AutoPasteNotifying
    private let targetApplicationProvider: any PasteTargetApplicationProviding
    private var targetApplication: (any PasteTargetApplication)?

    init(
        authorization: any PasteEventAuthorizing = SystemPasteEventAuthorization(),
        eventSender: any PasteEventSending = SystemPasteEventSender(),
        notifier: any AutoPasteNotifying = SystemAutoPasteNotifier(),
        targetApplicationProvider: any PasteTargetApplicationProviding = SystemPasteTargetApplicationProvider()
    ) {
        self.authorization = authorization
        self.eventSender = eventSender
        self.notifier = notifier
        self.targetApplicationProvider = targetApplicationProvider
    }

    func captureTargetApplication() {
        targetApplication = targetApplicationProvider.frontmostApplication()
    }

    func pasteIfEnabled(_ isEnabled: Bool) {
        guard isEnabled else {
            targetApplication = nil
            return
        }
        defer { targetApplication = nil }
        guard authorization.requestAccess(),
              let targetApplication,
              targetApplication.activateForPaste(),
              eventSender.sendPasteShortcut() else {
            notifier.notifyManualPasteRequired()
            return
        }
    }
}

@MainActor
final class HistorySelectionHandler {
    private let restorer: ClipboardRestorer
    private let autoPasteController: AutoPasteController
    private let isAutoPasteEnabled: () -> Bool

    init(
        restorer: ClipboardRestorer,
        autoPasteController: AutoPasteController,
        isAutoPasteEnabled: @escaping () -> Bool
    ) {
        self.restorer = restorer
        self.autoPasteController = autoPasteController
        self.isAutoPasteEnabled = isAutoPasteEnabled
    }

    func confirm(_ entry: HistoryEntry) throws {
        try restorer.restore(entry)
        autoPasteController.pasteIfEnabled(isAutoPasteEnabled())
    }
}
