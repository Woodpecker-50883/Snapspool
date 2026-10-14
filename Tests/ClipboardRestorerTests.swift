import AppKit
import XCTest
@testable import Snapspool

final class ClipboardRestorerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: temporaryDirectory.path) {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    @MainActor
    func testRestoresTextAsPlainUTF8WithRestoredMarker() throws {
        let pasteboard = FakeWritablePasteboard()
        let restorer = ClipboardRestorer(pasteboard: pasteboard)
        let textData = Data("restored text".utf8)
        let entry = HistoryEntry(content: .text(textData), detectionOrder: 0)

        try restorer.restore(entry)

        XCTAssertEqual(pasteboard.dataByType, [
            ClipboardContentSelector.plainTextType: textData,
            ClipboardContentSelector.restoredType: Data(),
        ])
    }

    @MainActor
    func testSystemPasteboardWriterBuildsNativeItemWithTextAndMarker() throws {
        let textData = Data("production adapter".utf8)
        let item = SystemClipboardPasteboardWriter.makeItem(with: [
            PasteboardRepresentation(
                type: ClipboardContentSelector.plainTextType,
                data: textData
            ),
            PasteboardRepresentation(
                type: ClipboardContentSelector.restoredType,
                data: Data()
            ),
        ])

        XCTAssertEqual(item.data(forType: ClipboardContentSelector.plainTextType), textData)
        XCTAssertEqual(item.data(forType: ClipboardContentSelector.restoredType), Data())
    }

    @MainActor
    func testRestoresImageAsExactSavedPNGAndValidTIFFWithSamePixelsAndColorSpace() throws {
        let pngData = try makePNGData()
        let fileURL = temporaryDirectory.appendingPathComponent("saved.png")
        try pngData.write(to: fileURL)
        let entry = HistoryEntry(
            content: .image(ImageHistoryEntry(fileURL: fileURL, isFallback: false)),
            detectionOrder: 0
        )
        let pasteboard = FakeWritablePasteboard()

        try ClipboardRestorer(pasteboard: pasteboard).restore(entry)

        XCTAssertEqual(pasteboard.dataByType[ClipboardContentSelector.pngType], pngData)
        let restoredTIFF = try XCTUnwrap(
            pasteboard.dataByType[ClipboardContentSelector.tiffType]
        )
        let original = try XCTUnwrap(NSBitmapImageRep(data: pngData))
        let restored = try XCTUnwrap(NSBitmapImageRep(data: restoredTIFF))
        XCTAssertEqual(restored.pixelsWide, original.pixelsWide)
        XCTAssertEqual(restored.pixelsHigh, original.pixelsHigh)
        XCTAssertEqual(restored.hasAlpha, original.hasAlpha)
        XCTAssertEqual(restored.colorSpaceName, original.colorSpaceName)
        XCTAssertEqual(restoredPixelData(restored), restoredPixelData(original))
        XCTAssertEqual(pasteboard.dataByType[ClipboardContentSelector.restoredType], Data())
    }

    @MainActor
    func testRestoredMarkerPreventsMonitorFromAddingHistoryOrSavingAnotherFile() throws {
        let pngData = try makePNGData()
        let fileURL = temporaryDirectory.appendingPathComponent("saved.png")
        try pngData.write(to: fileURL)
        let entry = HistoryEntry(
            content: .image(ImageHistoryEntry(fileURL: fileURL, isFallback: false)),
            detectionOrder: 0
        )
        let pasteboard = FakeWritablePasteboard()
        let destination = temporaryDirectory.appendingPathComponent("destination")
        let fallback = temporaryDirectory.appendingPathComponent("fallback")
        let historyStore = HistoryStore(imageIngestionService: ImageIngestionService(
            destinationSaver: ImageFolderSaver(destinationDirectory: destination),
            fallbackSaver: ImageFolderSaver(destinationDirectory: fallback),
            notifier: ClipboardRestorerSilentNotifier()
        ))
        let monitor = ClipboardMonitor(pasteboard: pasteboard) { content in
            historyStore.ingest(content)
        }

        try ClipboardRestorer(pasteboard: pasteboard).restore(entry)
        monitor.poll()

        XCTAssertTrue(historyStore.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fallback.path))
    }

    @MainActor
    func testReportsPasteboardWriteFailure() throws {
        let pasteboard = FakeWritablePasteboard(writeSucceeds: false)
        let entry = HistoryEntry(content: .text(Data("text".utf8)), detectionOrder: 0)

        XCTAssertThrowsError(try ClipboardRestorer(pasteboard: pasteboard).restore(entry)) { error in
            guard case ClipboardRestorationError.pasteboardWriteFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    @MainActor
    func testMissingSavedImageThrowsWithoutChangingPasteboard() throws {
        let missingURL = temporaryDirectory.appendingPathComponent("missing.png")
        let entry = HistoryEntry(
            content: .image(ImageHistoryEntry(fileURL: missingURL, isFallback: false)),
            detectionOrder: 0
        )
        let pasteboard = FakeWritablePasteboard()

        XCTAssertThrowsError(try ClipboardRestorer(pasteboard: pasteboard).restore(entry))
        XCTAssertEqual(pasteboard.replaceCallCount, 0)
        XCTAssertTrue(pasteboard.dataByType.isEmpty)
    }

    @MainActor
    func testCorruptSavedImageThrowsWithoutChangingPasteboard() throws {
        let corruptURL = temporaryDirectory.appendingPathComponent("corrupt.png")
        try Data("not an image".utf8).write(to: corruptURL)
        let entry = HistoryEntry(
            content: .image(ImageHistoryEntry(fileURL: corruptURL, isFallback: false)),
            detectionOrder: 0
        )
        let pasteboard = FakeWritablePasteboard()

        XCTAssertThrowsError(try ClipboardRestorer(pasteboard: pasteboard).restore(entry)) { error in
            guard case ClipboardRestorationError.invalidSavedImage = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(pasteboard.replaceCallCount, 0)
        XCTAssertTrue(pasteboard.dataByType.isEmpty)
    }

    private func makePNGData() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.setColor(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.25), atX: 0, y: 0)
        bitmap.setColor(NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 0.75), atX: 1, y: 0)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func restoredPixelData(_ bitmap: NSBitmapImageRep) -> [UInt8] {
        guard let data = bitmap.bitmapData else { return [] }
        return Array(UnsafeBufferPointer(
            start: data,
            count: bitmap.bytesPerRow * bitmap.pixelsHigh
        ))
    }
}

@MainActor
private final class FakeWritablePasteboard: ClipboardPasteboardWriting, ClipboardPasteboardReading {
    private let writeSucceeds: Bool
    private(set) var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
    private(set) var changeCount = 0
    private(set) var replaceCallCount = 0

    var items: [any PasteboardItemReading] {
        dataByType.isEmpty ? [] : [DictionaryPasteboardItem(dataByType: dataByType)]
    }

    init(writeSucceeds: Bool = true) {
        self.writeSucceeds = writeSucceeds
    }

    func replaceContents(with representations: [PasteboardRepresentation]) -> Bool {
        replaceCallCount += 1
        dataByType = Dictionary(uniqueKeysWithValues: representations.map { ($0.type, $0.data) })
        changeCount += 1
        return writeSucceeds
    }
}

private struct DictionaryPasteboardItem: PasteboardItemReading {
    let dataByType: [NSPasteboard.PasteboardType: Data]

    var types: [NSPasteboard.PasteboardType] { Array(dataByType.keys) }

    func data(forType type: NSPasteboard.PasteboardType) -> Data? {
        dataByType[type]
    }
}

private final class ClipboardRestorerSilentNotifier: ImageSaveNotifying, @unchecked Sendable {
    func notifyDestinationSaveFailed() {}
    func notifyFallbackSaveFailed() {}
}
