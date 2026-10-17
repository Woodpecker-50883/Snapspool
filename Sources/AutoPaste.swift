import AppKit
import Carbon.HIToolbox
import CoreGraphics

@MainActor
protocol PasteEventAuthorizing {
    func requestAccess(completion: @escaping (Bool) -> Void)
}

@MainActor
final class SystemPasteEventAuthorization: PasteEventAuthorizing {
    static let shared = SystemPasteEventAuthorization()
    static let recheckInterval: TimeInterval = 0.5

    private let preflightAccess: () -> Bool
    private let requestSystemAccess: () -> Bool
    private let scheduleRecheck: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private let isApplicationActive: () -> Bool
    private var completions: [(Bool) -> Void] = []
    private var isWaitingForSystemDialog = false

    init(
        preflightAccess: @escaping () -> Bool = { CGPreflightPostEventAccess() },
        requestSystemAccess: @escaping () -> Bool = { CGRequestPostEventAccess() },
        scheduleRecheck: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { interval, completion in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(interval))
                completion()
            }
        },
        isApplicationActive: @escaping () -> Bool = { NSApp?.isActive ?? false }
    ) {
        self.preflightAccess = preflightAccess
        self.requestSystemAccess = requestSystemAccess
        self.scheduleRecheck = scheduleRecheck
        self.isApplicationActive = isApplicationActive
    }

    func requestAccess(completion: @escaping (Bool) -> Void) {
        if preflightAccess() {
            completion(true)
            return
        }

        completions.append(completion)
        guard !isWaitingForSystemDialog else { return }

        isWaitingForSystemDialog = true

        if requestSystemAccess() {
            finishRequest(isAuthorized: true)
        } else {
            scheduleNextRecheck()
        }
    }

    private func scheduleNextRecheck() {
        scheduleRecheck(Self.recheckInterval) { [weak self] in
            self?.recheckAccess()
        }
    }

    private func recheckAccess() {
        guard isWaitingForSystemDialog else { return }

        if preflightAccess() {
            finishRequest(isAuthorized: true)
        } else if isApplicationActive() {
            // No system prompt is in front of the application, so an app-side
            // explanation can be shown without covering the system UI.
            finishRequest(isAuthorized: false)
        } else {
            // The system prompt owns focus. Keep polling rather than waiting
            // for an activation notification, which LSUIElement apps may not receive.
            scheduleNextRecheck()
        }
    }

    private func finishRequest(isAuthorized: Bool) {
        isWaitingForSystemDialog = false
        let pendingCompletions = completions
        completions.removeAll()
        pendingCompletions.forEach { $0(isAuthorized) }
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
    var permissionState: AutoPastePermissionState { get }
    func setPermissionStateHandler(_ handler: @escaping (AutoPastePermissionState) -> Void)
    func setSetupGuideVisible(_ isVisible: Bool)
    func requestPermissionFromSetup()
    func restartFromSetup()
}

enum AutoPastePermissionState: Equatable {
    case unauthorized
    case restartRequired
    case active
}

@MainActor
final class SystemAutoPasteNotifier: NSObject, AutoPasteNotifying, AutoPastePermissionGuiding {
    private static let pendingPermissionCheckKey =
        "autopaste.pendingPermissionCheckAfterRelaunch"
    static let permissionRecheckInterval: TimeInterval = 0.5

    static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!

    private let openURL: (URL) -> Bool
    private let runAlert: (NSAlert) -> NSApplication.ModalResponse
    private let requestAuthorization: (@escaping (Bool) -> Void) -> Void
    private let isAuthorized: () -> Bool
    private let isApplicationActive: () -> Bool
    private let schedulePermissionRecheck: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private let defaults: UserDefaults
    private let applicationURL: URL
    private let prepareForRelaunch: () -> Void
    private let relaunchApplication: (URL) -> Bool
    private let recoverFromFailedRelaunch: () -> Void
    private let terminateCurrentApplication: () -> Void
    private var isWaitingForSettingsReturn = false
    private var isSetupGuideVisible = false
    private var permissionStateHandler: ((AutoPastePermissionState) -> Void)?
    private(set) var permissionState: AutoPastePermissionState = .unauthorized {
        didSet {
            guard permissionState != oldValue else { return }
            permissionStateHandler?(permissionState)
        }
    }

    init(
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        runAlert: @escaping (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() },
        requestAuthorization: @escaping (@escaping (Bool) -> Void) -> Void = { completion in
            SystemPasteEventAuthorization.shared.requestAccess(completion: completion)
        },
        isAuthorized: @escaping () -> Bool = { CGPreflightPostEventAccess() },
        isApplicationActive: @escaping () -> Bool = { NSApp?.isActive ?? false },
        schedulePermissionRecheck: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { interval, completion in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(interval))
                completion()
            }
        },
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
        self.isApplicationActive = isApplicationActive
        self.schedulePermissionRecheck = schedulePermissionRecheck
        self.defaults = defaults
        self.applicationURL = applicationURL
        self.prepareForRelaunch = prepareForRelaunch
        self.relaunchApplication = relaunchApplication
        self.recoverFromFailedRelaunch = recoverFromFailedRelaunch
        self.terminateCurrentApplication = terminateCurrentApplication
        super.init()
        checkPermissionAfterRelaunchIfNeeded()
    }

    func notifyManualPasteRequired() {
        if isSetupGuideVisible {
            permissionState = isAuthorized() ? .active : .unauthorized
            return
        }

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
        requestAuthorization { [weak self] isAuthorized in
            guard let self else { return }
            if isAuthorized {
                permissionState = .active
            } else if isSetupGuideVisible {
                permissionState = .unauthorized
                if openURL(Self.accessibilitySettingsURL) {
                    startWaitingForSettingsReturn()
                }
            } else {
                notifyManualPasteRequired()
            }
        }
    }

    func setPermissionStateHandler(
        _ handler: @escaping (AutoPastePermissionState) -> Void
    ) {
        permissionStateHandler = handler
        handler(permissionState)
    }

    func setSetupGuideVisible(_ isVisible: Bool) {
        isSetupGuideVisible = isVisible
        guard isVisible else { return }
        refreshSetupPermissionState()
        scheduleSetupPermissionRefresh()
    }

    func restartFromSetup() {
        guard permissionState == .restartRequired else { return }
        restartApplication()
    }

    private func startWaitingForSettingsReturn() {
        guard !isWaitingForSettingsReturn else { return }
        isWaitingForSettingsReturn = true
        scheduleNextPermissionRecheck()
    }

    private func stopWaitingForSettingsReturn() {
        isWaitingForSettingsReturn = false
    }

    private func scheduleNextPermissionRecheck() {
        schedulePermissionRecheck(Self.permissionRecheckInterval) { [weak self] in
            self?.recheckPermissionAfterOpeningSettings()
        }
    }

    private func scheduleSetupPermissionRefresh() {
        schedulePermissionRecheck(Self.permissionRecheckInterval) { [weak self] in
            guard let self, isSetupGuideVisible else { return }
            refreshSetupPermissionState()
            scheduleSetupPermissionRefresh()
        }
    }

    private func refreshSetupPermissionState() {
        if isAuthorized() {
            permissionState = .active
        } else if permissionState == .active {
            permissionState = .unauthorized
        }
    }

    private func recheckPermissionAfterOpeningSettings() {
        guard isWaitingForSettingsReturn else { return }

        if isAuthorized() {
            stopWaitingForSettingsReturn()
            permissionState = .active
            if !isSetupGuideVisible {
                showPermissionEnabledAlert()
            }
        } else if isApplicationActive() {
            stopWaitingForSettingsReturn()
            permissionState = .restartRequired
            if !isSetupGuideVisible {
                showRestartOffer()
            }
        } else {
            scheduleNextPermissionRecheck()
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

        restartApplication()
    }

    private func restartApplication() {

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
        permissionState = .active
        if !isSetupGuideVisible {
            showPermissionEnabledAlert()
        }
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
        authorization.requestAccess { [weak self] isAuthorized in
            guard let self else { return }
            defer { targetApplication = nil }
            guard isAuthorized,
                  let targetApplication,
                  targetApplication.activateForPaste(),
                  eventSender.sendPasteShortcut() else {
                notifier.notifyManualPasteRequired()
                return
            }
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
