import AppKit
import XCTest
@testable import Snapspool

@MainActor
final class ClipboardMonitorTests: XCTestCase {
    func testPollingIntervalIsPointThreeSeconds() {
        XCTAssertEqual(ClipboardMonitor.pollingInterval, 0.3)
    }

    func testOnlyProcessesWhenChangeCountIncreases() {
        let pasteboard = FakePasteboard(changeCount: 10, items: [item(text: "first")])
        var detected: [ClipboardContent] = []
        let monitor = ClipboardMonitor(pasteboard: pasteboard) { detected.append($0) }

        monitor.poll()
        pasteboard.changeCount = 9
        monitor.poll()
        XCTAssertTrue(detected.isEmpty)

        pasteboard.changeCount = 11
        monitor.poll()
        XCTAssertEqual(detected, [.text(data: Data("first".utf8))])

        monitor.poll()
        XCTAssertEqual(detected.count, 1)
    }

    func testUsesCurrentChangeCountAsStartupBaseline() {
        let pasteboard = FakePasteboard(changeCount: 10, items: [item(text: "before launch")])
        var detected: [ClipboardContent] = []
        let monitor = ClipboardMonitor(pasteboard: pasteboard) { detected.append($0) }

        monitor.poll()

        XCTAssertTrue(detected.isEmpty)
    }

    func testChangeDuringReadIsDetectedOnNextPollWithMatchingContent() {
        let pasteboard = FakePasteboard(changeCount: 10, items: [item(text: "initial")])
        var detected: [ClipboardContent] = []
        let monitor = ClipboardMonitor(pasteboard: pasteboard) { detected.append($0) }

        pasteboard.changeCount = 11
        pasteboard.items = [CallbackPasteboardItem(text: "superseded during read") {
            pasteboard.changeCount = 12
            pasteboard.items = [self.item(text: "latest")]
        }]

        monitor.poll()
        XCTAssertTrue(detected.isEmpty)

        monitor.poll()
        XCTAssertEqual(detected, [.text(data: Data("latest".utf8))])
    }

    func testPauseSuppressesDetectionAndResumeDiscardsChangesMadeWhilePaused() {
        let pasteboard = FakePasteboard(changeCount: 10, items: [item(text: "initial")])
        var detected: [ClipboardContent] = []
        let monitor = ClipboardMonitor(pasteboard: pasteboard) { detected.append($0) }

        monitor.pause()
        pasteboard.changeCount = 11
        pasteboard.items = [item(text: "while paused")]
        monitor.poll()
        XCTAssertTrue(detected.isEmpty)

        monitor.resume()
        monitor.poll()
        XCTAssertTrue(detected.isEmpty)

        pasteboard.changeCount = 12
        pasteboard.items = [item(text: "after resume")]
        monitor.poll()
        XCTAssertEqual(detected, [.text(data: Data("after resume".utf8))])
    }

    func testPausedStateIsNotPersistedAcrossMonitorInstances() {
        let pasteboard = FakePasteboard(changeCount: 1, items: [])
        let firstMonitor = ClipboardMonitor(pasteboard: pasteboard) { _ in }
        firstMonitor.pause()

        let relaunchedMonitor = ClipboardMonitor(pasteboard: pasteboard) { _ in }

        XCTAssertTrue(firstMonitor.isPaused)
        XCTAssertFalse(relaunchedMonitor.isPaused)
    }

    func testSelectsEachSupportedType() {
        let representations: [(NSPasteboard.PasteboardType, ClipboardContent)] = [
            (.init("public.png"), .image(data: Data([1]), type: .init("public.png"))),
            (.init("public.tiff"), .image(data: Data([2]), type: .init("public.tiff"))),
            (.init("public.jpeg"), .image(data: Data([3]), type: .init("public.jpeg"))),
            (.init("public.utf8-plain-text"), .text(data: Data([4]))),
        ]

        for (type, expected) in representations {
            let candidate = ClipboardContentSelector.select(
                from: [FakePasteboardItem(dataByType: [type: data(in: expected)])]
            )
            XCTAssertEqual(candidate, expected, "Failed to select \(type.rawValue)")
        }
    }

    func testUsesImageTypePriorityAndReturnsOnlyOneRepresentation() {
        let priorityCases: [([NSPasteboard.PasteboardType: Data], ClipboardContent)] = [
            ([
                ClipboardContentSelector.plainTextType: Data("text".utf8),
                ClipboardContentSelector.jpegType: Data([3]),
                ClipboardContentSelector.tiffType: Data([2]),
                ClipboardContentSelector.pngType: Data([1]),
            ], .image(data: Data([1]), type: ClipboardContentSelector.pngType)),
            ([
                ClipboardContentSelector.plainTextType: Data("text".utf8),
                ClipboardContentSelector.jpegType: Data([3]),
                ClipboardContentSelector.tiffType: Data([2]),
            ], .image(data: Data([2]), type: ClipboardContentSelector.tiffType)),
            ([
                ClipboardContentSelector.plainTextType: Data("text".utf8),
                ClipboardContentSelector.jpegType: Data([3]),
            ], .image(data: Data([3]), type: ClipboardContentSelector.jpegType)),
        ]

        for (representations, expected) in priorityCases {
            XCTAssertEqual(
                ClipboardContentSelector.select(
                    from: [FakePasteboardItem(dataByType: representations)]
                ),
                expected
            )
        }
    }

    func testOnlyExaminesFirstPasteboardItem() {
        let unsupported = FakePasteboardItem(dataByType: [
            .init("public.html"): Data("<p>ignored</p>".utf8),
        ])

        XCTAssertNil(
            ClipboardContentSelector.select(from: [unsupported, item(text: "second")])
        )
    }

    func testRejectsItemsContainingOnlyRTFOrHTML() {
        for type in [NSPasteboard.PasteboardType("public.rtf"), .init("public.html")] {
            let item = FakePasteboardItem(dataByType: [type: Data([1])])
            XCTAssertNil(ClipboardContentSelector.select(from: [item]))
        }
    }

    func testRejectsConcealedTransientAndAutogeneratedItems() {
        let excludedTypes = [
            "org.nspasteboard.ConcealedType",
            "org.nspasteboard.TransientType",
            "org.nspasteboard.AutoGeneratedType",
        ]

        for excludedType in excludedTypes {
            let item = FakePasteboardItem(dataByType: [
                ClipboardContentSelector.pngType: Data([1]),
                .init(excludedType): Data(),
            ])
            XCTAssertNil(
                ClipboardContentSelector.select(from: [item]),
                "Expected \(excludedType) to be excluded"
            )
        }
    }

    func testRejectsTextLargerThanOneMiBButAcceptsExactLimit() {
        let exactLimit = FakePasteboardItem(dataByType: [
            ClipboardContentSelector.plainTextType:
                Data(repeating: 0x61, count: ClipboardContentSelector.maximumTextByteCount),
        ])
        let overLimit = FakePasteboardItem(dataByType: [
            ClipboardContentSelector.plainTextType:
                Data(repeating: 0x61, count: ClipboardContentSelector.maximumTextByteCount + 1),
        ])

        XCTAssertNotNil(ClipboardContentSelector.select(from: [exactLimit]))
        XCTAssertNil(ClipboardContentSelector.select(from: [overLimit]))
    }

    func testRejectsRestoredItems() {
        let item = FakePasteboardItem(dataByType: [
            ClipboardContentSelector.plainTextType: Data("restored".utf8),
            ClipboardContentSelector.restoredType: Data(),
        ])

        XCTAssertNil(ClipboardContentSelector.select(from: [item]))
    }

    private func item(text: String) -> FakePasteboardItem {
        FakePasteboardItem(dataByType: [
            ClipboardContentSelector.plainTextType: Data(text.utf8),
        ])
    }

    private func data(in content: ClipboardContent) -> Data {
        switch content {
        case let .image(data, _), let .text(data): data
        }
    }
}

@MainActor
private final class FakePasteboard: ClipboardPasteboardReading {
    var changeCount: Int
    var items: [any PasteboardItemReading]

    init(changeCount: Int, items: [any PasteboardItemReading]) {
        self.changeCount = changeCount
        self.items = items
    }
}

private final class CallbackPasteboardItem: PasteboardItemReading {
    let types = [ClipboardContentSelector.plainTextType]
    private let data: Data
    private var onDataRead: (() -> Void)?

    init(text: String, onDataRead: @escaping () -> Void) {
        data = Data(text.utf8)
        self.onDataRead = onDataRead
    }

    func data(forType type: NSPasteboard.PasteboardType) -> Data? {
        guard type == ClipboardContentSelector.plainTextType else { return nil }
        let callback = onDataRead
        onDataRead = nil
        callback?()
        return data
    }
}

private struct FakePasteboardItem: PasteboardItemReading {
    let dataByType: [NSPasteboard.PasteboardType: Data]

    var types: [NSPasteboard.PasteboardType] {
        Array(dataByType.keys)
    }

    func data(forType type: NSPasteboard.PasteboardType) -> Data? {
        dataByType[type]
    }
}
