import AppKit
import XCTest
@testable import Snapspool

@MainActor
final class HistoryPickerTests: XCTestCase {
    func testEntriesRemainInUnifiedNewestFirstOrder() {
        let older = HistoryEntry(content: .text(Data("older".utf8)), detectionOrder: 1)
        let newer = HistoryEntry(content: .text(Data("newer".utf8)), detectionOrder: 2)
        let model = HistoryPickerModel(entries: [newer, older])

        XCTAssertEqual(model.entries.map(\.id), [newer.id, older.id])
        XCTAssertEqual(model.selectedID, newer.id)
    }

    func testTextPreviewUsesFirstLineAndAtMostEightyCharacters() {
        let multiline = HistoryEntry(
            content: .text(Data((String(repeating: "a", count: 90) + "\nignored").utf8)),
            detectionOrder: 0
        )
        let model = HistoryPickerModel(entries: [multiline])

        let preview = model.textPreview(for: multiline)
        XCTAssertEqual(preview?.count, 80)
        XCTAssertEqual(preview?.last, "…")
        XCTAssertFalse(preview?.contains("ignored") == true)
    }

    func testTextPreviewPreservesAnEmptyFirstLine() {
        let multiline = HistoryEntry(
            content: .text(Data("\nsecond line".utf8)),
            detectionOrder: 0
        )
        let model = HistoryPickerModel(entries: [multiline])

        XCTAssertEqual(model.textPreview(for: multiline), "")
    }

    func testArrowSelectionIsClampedAndEnterConfirmsSelection() {
        let first = HistoryEntry(content: .text(Data("first".utf8)), detectionOrder: 2)
        let second = HistoryEntry(content: .text(Data("second".utf8)), detectionOrder: 1)
        var confirmed: HistoryEntry?
        var dismissCount = 0
        let model = HistoryPickerModel(
            entries: [first, second],
            onConfirm: { confirmed = $0 },
            onDismiss: { dismissCount += 1 }
        )

        model.moveSelection(by: -1)
        XCTAssertEqual(model.selectedID, first.id)
        model.moveSelection(by: 1)
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedID, second.id)
        model.confirmSelection()

        XCTAssertEqual(confirmed, second)
        XCTAssertEqual(dismissCount, 1)
    }

    func testSingleClickConfirmationAndEscapeDismissal() {
        let entry = HistoryEntry(content: .text(Data("text".utf8)), detectionOrder: 0)
        var confirmed: HistoryEntry?
        var dismissCount = 0
        let model = HistoryPickerModel(
            entries: [entry],
            onConfirm: { confirmed = $0 },
            onDismiss: { dismissCount += 1 }
        )

        model.confirm(entry)
        XCTAssertEqual(confirmed, entry)
        XCTAssertEqual(dismissCount, 1)

        model.cancel()
        XCTAssertEqual(dismissCount, 2)
    }

    func testEmptyHistoryHasNoSelectionOrConfirmation() {
        var didConfirm = false
        let model = HistoryPickerModel(entries: [], onConfirm: { _ in didConfirm = true })

        model.moveSelection(by: 1)
        model.confirmSelection()

        XCTAssertNil(model.selectedID)
        XCTAssertFalse(didConfirm)
    }

    func testImageThumbnailLongestEdgeIsAtMost256Pixels() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("large.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 800,
            pixelsHigh: 400,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: fileURL)

        let thumbnail = try XCTUnwrap(HistoryThumbnail.make(from: fileURL))
        let representation = try XCTUnwrap(thumbnail.representations.first)

        XCTAssertEqual(representation.pixelsWide, 256)
        XCTAssertEqual(representation.pixelsHigh, 128)
    }
}
