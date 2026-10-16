import AppKit
import Carbon.HIToolbox
import Foundation

struct GlobalShortcut: Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let defaultShortcut = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(cmdKey | shiftKey)
    )

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        self.init(
            keyCode: UInt32(keyCode),
            modifiers: Self.carbonModifiers(from: modifierFlags)
        )
    }

    var validationError: GlobalShortcutValidationError? {
        let supportedModifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        let selectedModifiers = modifiers & supportedModifiers
        guard selectedModifiers != 0 else { return .modifierRequired }

        // Since macOS Sequoia, Carbon does not reliably register global
        // shortcuts whose modifiers consist only of Shift and/or Option.
        let reliableModifiers = UInt32(cmdKey | controlKey)
        guard selectedModifiers & reliableModifiers != 0 else {
            return .unsupportedShiftOptionOnly
        }
        return nil
    }

    var displayString: String {
        var display = ""
        if modifiers & UInt32(controlKey) != 0 { display += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { display += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { display += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { display += "⌘" }
        return display + Self.keyDisplayName(keyCode)
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }

    private static func keyDisplayName(_ keyCode: UInt32) -> String {
        let names: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B",
            UInt32(kVK_ANSI_C): "C", UInt32(kVK_ANSI_D): "D",
            UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H",
            UInt32(kVK_ANSI_I): "I", UInt32(kVK_ANSI_J): "J",
            UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N",
            UInt32(kVK_ANSI_O): "O", UInt32(kVK_ANSI_P): "P",
            UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T",
            UInt32(kVK_ANSI_U): "U", UInt32(kVK_ANSI_V): "V",
            UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1",
            UInt32(kVK_ANSI_2): "2", UInt32(kVK_ANSI_3): "3",
            UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7",
            UInt32(kVK_ANSI_8): "8", UInt32(kVK_ANSI_9): "9",
            UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩",
            UInt32(kVK_Tab): "⇥", UInt32(kVK_Delete): "⌫",
            UInt32(kVK_ForwardDelete): "⌦", UInt32(kVK_Home): "↖",
            UInt32(kVK_End): "↘", UInt32(kVK_PageUp): "⇞",
            UInt32(kVK_PageDown): "⇟", UInt32(kVK_LeftArrow): "←",
            UInt32(kVK_RightArrow): "→", UInt32(kVK_UpArrow): "↑",
            UInt32(kVK_DownArrow): "↓"
        ]
        if let name = names[keyCode] { return name }
        let functionKeyCodes: [UInt32] = [
            UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4),
            UInt32(kVK_F5), UInt32(kVK_F6), UInt32(kVK_F7), UInt32(kVK_F8),
            UInt32(kVK_F9), UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12),
            UInt32(kVK_F13), UInt32(kVK_F14), UInt32(kVK_F15), UInt32(kVK_F16),
            UInt32(kVK_F17), UInt32(kVK_F18), UInt32(kVK_F19), UInt32(kVK_F20)
        ]
        if let index = functionKeyCodes.firstIndex(of: keyCode) {
            return "F\(index + 1)"
        }
        return "Key \(keyCode)"
    }
}

enum GlobalShortcutValidationError: Equatable {
    case modifierRequired
    case unsupportedShiftOptionOnly
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
    typealias RegisterEventHotKeyFunction = (
        UInt32,
        UInt32,
        EventHotKeyID,
        EventTargetRef?,
        OptionBits,
        UnsafeMutablePointer<EventHotKeyRef?>?
    ) -> OSStatus

    nonisolated static let eventSignature: OSType = 0x534E_4150 // "SNAP"
    nonisolated static let eventID: UInt32 = 1

    private let registerEventHotKey: RegisterEventHotKeyFunction
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    nonisolated(unsafe) private var action: (@MainActor @Sendable () -> Void)?

    init(
        registerEventHotKey: @escaping RegisterEventHotKeyFunction = RegisterEventHotKey
    ) {
        self.registerEventHotKey = registerEventHotKey
    }

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
        let registrationStatus = registerEventHotKey(
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
    private(set) var configuredShortcut: GlobalShortcut
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

    /// Tries a user-selected shortcut immediately. A failed candidate is never
    /// accepted: the previously active shortcut is registered again.
    @discardableResult
    func updateShortcut(_ candidate: GlobalShortcut) -> Bool {
        let previous = configuredShortcut
        if registrar.register(candidate, handler: showHistoryPicker) {
            configuredShortcut = candidate
            hasRegistrationWarning = false
            return true
        }

        let restored = registrar.register(previous, handler: showHistoryPicker)
        hasRegistrationWarning = !restored
        return false
    }
}
