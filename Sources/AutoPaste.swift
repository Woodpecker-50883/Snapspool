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
struct SystemAutoPasteNotifier: AutoPasteNotifying {
    static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!

    private let openURL: (URL) -> Bool
    private let runAlert: (NSAlert) -> NSApplication.ModalResponse

    init(
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        runAlert: @escaping (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }
    ) {
        self.openURL = openURL
        self.runAlert = runAlert
    }

    func notifyManualPasteRequired() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.string("autopaste.permission-required-title")
        alert.informativeText = L10n.string("autopaste.permission-required-message")
        alert.addButton(withTitle: L10n.string("autopaste.open-accessibility-settings"))
        alert.addButton(withTitle: L10n.string("common.ok"))
        if runAlert(alert) == .alertFirstButtonReturn {
            _ = openURL(Self.accessibilitySettingsURL)
        }
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
