import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Snapspool

@MainActor
final class GlobalHotKeyTests: XCTestCase {
    func testDefaultShortcutIsCommandShiftV() {
        XCTAssertEqual(GlobalShortcut.defaultShortcut.keyCode, UInt32(kVK_ANSI_V))
        XCTAssertEqual(
            GlobalShortcut.defaultShortcut.modifiers,
            UInt32(cmdKey | shiftKey)
        )
    }

    func testFailedConfiguredShortcutRetriesDefaultAndOpensPicker() {
        let registrar = FakeGlobalHotKeyRegistrar(results: [false, true])
        var openCount = 0
        let configured = GlobalShortcut(
            keyCode: UInt32(kVK_ANSI_B),
            modifiers: UInt32(cmdKey | optionKey)
        )
        let controller = GlobalHotKeyController(
            registrar: registrar,
            configuredShortcut: configured,
            showHistoryPicker: { openCount += 1 }
        )

        XCTAssertTrue(controller.start())
        XCTAssertEqual(registrar.attempts, [configured, .defaultShortcut])
        XCTAssertFalse(controller.hasRegistrationWarning)

        registrar.registeredHandler?()
        XCTAssertEqual(openCount, 1)
    }

    func testBothRegistrationAttemptsFailAndExposeWarning() {
        let registrar = FakeGlobalHotKeyRegistrar(results: [false, false])
        let controller = GlobalHotKeyController(registrar: registrar) {}

        XCTAssertFalse(controller.start())
        XCTAssertEqual(
            registrar.attempts,
            [.defaultShortcut, .defaultShortcut]
        )
        XCTAssertTrue(controller.hasRegistrationWarning)
    }

    func testCarbonRegistrarProductionEventAdapterReceivesHotKeyEvent() throws {
        // A standalone XCTest bundle has no NSApplication until requested,
        // whereas the production app has one before runtime startup.
        _ = NSApplication.shared
        let registrar = CarbonGlobalHotKeyRegistrar()
        var invocationCount = 0
        XCTAssertTrue(registrar.installEventHandler { invocationCount += 1 })
        defer { registrar.unregister() }

        var event: EventRef?
        XCTAssertEqual(
            CreateEvent(
                nil,
                OSType(kEventClassKeyboard),
                UInt32(kEventHotKeyPressed),
                GetCurrentEventTime(),
                EventAttributes(kEventAttributeUserEvent),
                &event
            ),
            noErr
        )
        var identifier = EventHotKeyID(
            signature: CarbonGlobalHotKeyRegistrar.eventSignature,
            id: CarbonGlobalHotKeyRegistrar.eventID
        )
        XCTAssertEqual(
            SetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                MemoryLayout<EventHotKeyID>.size,
                &identifier
            ),
            noErr
        )
        XCTAssertEqual(SendEventToEventTarget(event, GetApplicationEventTarget()), noErr)
        XCTAssertEqual(invocationCount, 1)
    }
}

@MainActor
private final class FakeGlobalHotKeyRegistrar: GlobalHotKeyRegistering {
    private var results: [Bool]
    private(set) var attempts: [GlobalShortcut] = []
    private(set) var registeredHandler: (@MainActor @Sendable () -> Void)?

    init(results: [Bool]) {
        self.results = results
    }

    func register(
        _ shortcut: GlobalShortcut,
        handler: @MainActor @Sendable @escaping () -> Void
    ) -> Bool {
        attempts.append(shortcut)
        let result = results.removeFirst()
        registeredHandler = result ? handler : nil
        return result
    }

    func unregister() {
        registeredHandler = nil
    }
}
