import Carbon.HIToolbox
import Foundation

struct GlobalShortcut: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let defaultShortcut = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(cmdKey | shiftKey)
    )
}

@MainActor
protocol GlobalHotKeyRegistering: AnyObject {
    func register(
        _ shortcut: GlobalShortcut,
        handler: @MainActor @Sendable @escaping () -> Void
    ) -> Bool
    func unregister()
}

final class CarbonGlobalHotKeyRegistrar: GlobalHotKeyRegistering, @unchecked Sendable {
    nonisolated static let eventSignature: OSType = 0x534E_4150 // "SNAP"
    nonisolated static let eventID: UInt32 = 1

    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    nonisolated(unsafe) private var action: (@MainActor @Sendable () -> Void)?

    func register(
        _ shortcut: GlobalShortcut,
        handler: @MainActor @Sendable @escaping () -> Void
    ) -> Bool {
        unregister()
        guard installEventHandler(handler) else { return false }

        var registeredHotKey: EventHotKeyRef?
        let identifier = EventHotKeyID(
            signature: Self.eventSignature,
            id: Self.eventID
        )
        let registrationStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )
        guard registrationStatus == noErr, let registeredHotKey else {
            unregister()
            return false
        }

        hotKey = registeredHotKey
        return true
    }

    /// Installs the same Carbon event route used by registration. Kept as a
    /// separate operation because standalone XCTest processes cannot register
    /// a global key, but can exercise the production event adapter end to end.
    func installEventHandler(
        _ handler: @MainActor @Sendable @escaping () -> Void
    ) -> Bool {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotKeyEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard installStatus == noErr else {
            eventHandler = nil
            return false
        }
        action = handler
        return true
    }

    func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        action = nil
    }

    nonisolated fileprivate func handle(_ event: EventRef) -> OSStatus {
        var identifier = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &identifier
        )
        guard status == noErr,
              identifier.signature == Self.eventSignature,
              identifier.id == Self.eventID else {
            return OSStatus(eventNotHandledErr)
        }
        MainActor.assumeIsolated {
            action?()
        }
        return noErr
    }
}

private func carbonHotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    return Unmanaged<CarbonGlobalHotKeyRegistrar>
        .fromOpaque(userData)
        .takeUnretainedValue()
        .handle(event)
}

@MainActor
final class GlobalHotKeyController {
    private let registrar: any GlobalHotKeyRegistering
    private let configuredShortcut: GlobalShortcut
    private let showHistoryPicker: @MainActor @Sendable () -> Void

    private(set) var hasRegistrationWarning = false

    init(
        registrar: any GlobalHotKeyRegistering = CarbonGlobalHotKeyRegistrar(),
        configuredShortcut: GlobalShortcut = .defaultShortcut,
        showHistoryPicker: @MainActor @Sendable @escaping () -> Void
    ) {
        self.registrar = registrar
        self.configuredShortcut = configuredShortcut
        self.showHistoryPicker = showHistoryPicker
    }

    @discardableResult
    func start() -> Bool {
        hasRegistrationWarning = false
        if registrar.register(configuredShortcut, handler: showHistoryPicker) {
            return true
        }
        if registrar.register(.defaultShortcut, handler: showHistoryPicker) {
            return true
        }
        hasRegistrationWarning = true
        return false
    }

    func stop() {
        registrar.unregister()
    }
}
