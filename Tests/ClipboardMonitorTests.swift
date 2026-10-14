import AppKit
import XCTest
@testable import Snapspool

@MainActor
final class ClipboardMonitorTests: XCTestCase {
    func testPollsAtApproximatelyPointThreeSecondIntervals() {
        let pasteboard = PollTrackingPasteboard()
        let monitor = ClipboardMonitor(pasteboard: pasteboard) { _ in }
        let start = ProcessInfo.processInfo.systemUptime
        monitor.start()
        defer { monitor.stop() }

        XCTAssertTrue(
            runMainRunLoop(until: { pasteboard.changeCountReadTimes.count >= 6 }, timeout: 1.85),
            "Expected five timer-driven pasteboard polls within the 0.3-second cadence deadline"
        )

        let timerPolls = Array(pasteboard.changeCountReadTimes.dropFirst().prefix(5))
        XCTAssertEqual(timerPolls.count, 5)
        guard timerPolls.count == 5 else { return }

        let firstFireDelay = timerPolls[0] - start
        let fourIntervalDuration = timerPolls[4] - timerPolls[0]
        XCTAssertGreaterThanOrEqual(firstFireDelay, 0.24)
        XCTAssertLessThan(firstFireDelay, 0.39)
        XCTAssertGreaterThanOrEqual(fourIntervalDuration, 1.04)
        XCTAssertLessThan(fourIntervalDuration, 1.50)
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

    func testPauseStopsTimerPollingAndResumeRestartsIt() {
        let pasteboard = PollTrackingPasteboard()
        let monitor = ClipboardMonitor(pasteboard: pasteboard) { _ in }
        monitor.start()
        defer { monitor.stop() }

        XCTAssertTrue(
            runMainRunLoop(until: { pasteboard.changeCountReadTimes.count >= 2 }, timeout: 0.8),
            "Expected polling to begin after start()"
        )

        monitor.pause()
        let readCountAtPause = pasteboard.changeCountReadTimes.count
        runMainRunLoop(for: 0.45)
        XCTAssertEqual(pasteboard.changeCountReadTimes.count, readCountAtPause)

        monitor.resume()
        let readCountAfterResumeBaseline = pasteboard.changeCountReadTimes.count
        XCTAssertEqual(readCountAfterResumeBaseline, readCountAtPause + 1)
        XCTAssertTrue(
            runMainRunLoop(
                until: { pasteboard.changeCountReadTimes.count > readCountAfterResumeBaseline },
                timeout: 0.8
            ),
            "Expected timer polling to restart after resume()"
        )
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

    func testRejectsMultibyteTextLargerThanOneMiBButAcceptsExactByteLimit() {
        let exactLimitData = Data(String(repeating: "é", count: 524_288).utf8)
        let overLimitData = Data((String(repeating: "é", count: 524_288) + "é").utf8)
        XCTAssertEqual(exactLimitData.count, 1_048_576)
        XCTAssertEqual(overLimitData.count, 1_048_578)

        let exactLimit = FakePasteboardItem(dataByType: [
            ClipboardContentSelector.plainTextType: exactLimitData,
        ])
        let overLimit = FakePasteboardItem(dataByType: [
            ClipboardContentSelector.plainTextType: overLimitData,
        ])

        XCTAssertNotNil(ClipboardContentSelector.select(from: [exactLimit]))
        XCTAssertNil(ClipboardContentSelector.select(from: [overLimit]))
    }

    func testProductionNSPasteboardItemAdapterDetectsRealAppKitItem() {
        let pasteboard = FakePasteboard(changeCount: 1, items: [])
        var detected: [ClipboardContent] = []
        let monitor = ClipboardMonitor(pasteboard: pasteboard) { detected.append($0) }
        let appKitItem = NSPasteboardItem()
        let expectedData = Data("AppKit pasteboard item".utf8)
        XCTAssertTrue(
            appKitItem.setData(expectedData, forType: ClipboardContentSelector.plainTextType)
        )
        pasteboard.items = [appKitItem]
        pasteboard.changeCount = 2

        monitor.poll()

        XCTAssertEqual(detected, [.text(data: expectedData)])
    }

    func testRejectsRestoredItems() {
        let item = FakePasteboardItem(dataByType: [
            ClipboardContentSelector.plainTextType: Data("restored".utf8),
            ClipboardContentSelector.restoredType: Data(),
        ])

        XCTAssertNil(ClipboardContentSelector.select(from: [item]))
    }

    func testRejectsFileAndFolderItemsEvenWhenTheyAlsoContainSupportedContent() {
        let supportedRepresentations: [[NSPasteboard.PasteboardType: Data]] = [
            [ClipboardContentSelector.plainTextType: Data("/Users/example/copied-file".utf8)],
            [ClipboardContentSelector.pngType: Data([1, 2, 3])],
        ]

        for fileType in [
            ClipboardContentSelector.fileURLType,
            ClipboardContentSelector.legacyFilenamesType,
        ] {
            for supportedRepresentation in supportedRepresentations {
                var representations = supportedRepresentation
                representations[fileType] = Data("file:///Users/example/copied-file".utf8)

                XCTAssertNil(
                    ClipboardContentSelector.select(from: [
                        FakePasteboardItem(dataByType: representations),
                    ]),
                    "Expected items containing \(fileType.rawValue) to be excluded"
                )
            }
        }
    }

    func testFileCopyDoesNotReachHistoryOrCreateAFile() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        let pasteboard = FakePasteboard(changeCount: 1, items: [])
        var history: [ClipboardContent] = []
        let saver = ImageFolderSaver(destinationDirectory: destination)
        let monitor = ClipboardMonitor(pasteboard: pasteboard) { content in
            history.append(content)
            _ = try? saver.save(content)
        }

        pasteboard.items = [FakePasteboardItem(dataByType: [
            ClipboardContentSelector.fileURLType: Data("file:///tmp/copied.png".utf8),
            ClipboardContentSelector.pngType: Data([1, 2, 3]),
            ClipboardContentSelector.plainTextType: Data("/tmp/copied.png".utf8),
        ])]
        pasteboard.changeCount = 2
        monitor.poll()

        XCTAssertTrue(history.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testMonitoringLeavesLatestAppKitPasteboardFileCopyUnchanged() throws {
        let pasteboard = FakePasteboard(changeCount: 1, items: [])
        var detected: [ClipboardContent] = []
        let monitor = ClipboardMonitor(pasteboard: pasteboard) { detected.append($0) }

        let latestItem = NSPasteboardItem()
        let fileURLData = Data("file:///tmp/latest-copy".utf8)
        let textData = Data("/tmp/latest-copy".utf8)
        XCTAssertTrue(latestItem.setData(
            fileURLData,
            forType: ClipboardContentSelector.fileURLType
        ))
        XCTAssertTrue(latestItem.setData(
            textData,
            forType: ClipboardContentSelector.plainTextType
        ))
        pasteboard.items = [latestItem]
        pasteboard.changeCount = 2

        monitor.poll()

        XCTAssertTrue(detected.isEmpty)
        XCTAssertEqual(pasteboard.changeCount, 2)
        XCTAssertIdentical(pasteboard.items.first as AnyObject, latestItem)
        XCTAssertTrue(latestItem.types.contains(ClipboardContentSelector.fileURLType))
        XCTAssertEqual(latestItem.data(forType: ClipboardContentSelector.fileURLType), fileURLData)
        XCTAssertEqual(latestItem.data(forType: ClipboardContentSelector.plainTextType), textData)
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

    private func runMainRunLoop(
        until condition: () -> Bool,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.01)))
        }
        return condition()
    }

    private func runMainRunLoop(for duration: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
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

@MainActor
private final class PollTrackingPasteboard: ClipboardPasteboardReading {
    private(set) var changeCountReadTimes: [TimeInterval] = []

    var changeCount: Int {
        changeCountReadTimes.append(ProcessInfo.processInfo.systemUptime)
        return 0
    }

    var items: [any PasteboardItemReading] = []
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
