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

    func testAuthorizedAutoPasteSendsCommandVWithoutFallbackNotice() {
        let log = AutoPasteCallLog()
        let controller = makeController(log: log, isAuthorized: true)

        controller.pasteIfEnabled(true)

        XCTAssertEqual(log.calls, ["authorize", "send"])
    }

    func testHistorySelectionRestoresClipboardBeforeSendingPaste() throws {
        let log = AutoPasteCallLog()
        let pasteboard = LoggedPasteboard(log: log)
        let handler = HistorySelectionHandler(
            restorer: ClipboardRestorer(pasteboard: pasteboard),
            autoPasteController: makeController(log: log, isAuthorized: true),
            isAutoPasteEnabled: { true }
        )
        let entry = HistoryEntry(
            content: .text(Data("chosen history".utf8)),
            detectionOrder: 0
        )

        try handler.confirm(entry)

        XCTAssertEqual(log.calls, ["restore", "authorize", "send"])
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
        isAuthorized: Bool
    ) -> AutoPasteController {
        AutoPasteController(
            authorization: LoggedAuthorization(log: log, result: isAuthorized),
            eventSender: LoggedEventSender(log: log),
            notifier: LoggedAutoPasteNotifier(log: log)
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
