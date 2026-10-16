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
    func notifyManualPasteRequired() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.string("autopaste.permission-required-title")
        alert.informativeText = L10n.string("autopaste.permission-required-message")
        alert.addButton(withTitle: L10n.string("common.ok"))
        alert.runModal()
    }
}

@MainActor
final class AutoPasteController {
    private let authorization: any PasteEventAuthorizing
    private let eventSender: any PasteEventSending
    private let notifier: any AutoPasteNotifying

    init(
        authorization: any PasteEventAuthorizing = SystemPasteEventAuthorization(),
        eventSender: any PasteEventSending = SystemPasteEventSender(),
        notifier: any AutoPasteNotifying = SystemAutoPasteNotifier()
    ) {
        self.authorization = authorization
        self.eventSender = eventSender
        self.notifier = notifier
    }

    func pasteIfEnabled(_ isEnabled: Bool) {
        guard isEnabled else { return }
        guard authorization.requestAccess(), eventSender.sendPasteShortcut() else {
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
