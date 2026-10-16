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

    func testHeaderCountsImagesAndTextsSeparately() {
        let text = HistoryEntry(content: .text(Data("text".utf8)), detectionOrder: 3)
        let firstImage = HistoryEntry(
            content: .image(ImageHistoryEntry(
                fileURL: URL(fileURLWithPath: "/tmp/first.png"),
                isFallback: false
            )),
            detectionOrder: 2
        )
        let secondImage = HistoryEntry(
            content: .image(ImageHistoryEntry(
                fileURL: URL(fileURLWithPath: "/tmp/second.png"),
                isFallback: false
            )),
            detectionOrder: 1
        )
        let model = HistoryPickerModel(entries: [text, firstImage, secondImage])

        XCTAssertEqual(model.imageCount, 2)
        XCTAssertEqual(model.textCount, 1)
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

    func testFailedRestorationDisplaysErrorAndKeepsPickerOpen() {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        let entry = HistoryEntry(
            content: .image(ImageHistoryEntry(fileURL: missingURL, isFallback: false)),
            detectionOrder: 0
        )
        let pasteboard = HistoryPickerWritablePasteboard()
        var dismissCount = 0
        let restorer = ClipboardRestorer(pasteboard: pasteboard)
        let model = HistoryPickerModel(
            entries: [entry],
            onConfirm: { try restorer.restore($0) },
            onDismiss: { dismissCount += 1 }
        )

        model.confirmSelection()

        XCTAssertEqual(model.restorationErrorMessage, L10n.string("history.restore-failed"))
        XCTAssertEqual(dismissCount, 0)
        XCTAssertEqual(pasteboard.replaceCallCount, 0)
    }

    func testSuccessfulRestorationClearsPreviousErrorAndDismissesPicker() {
        let missingEntry = HistoryEntry(
            content: .image(ImageHistoryEntry(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString),
                isFallback: false
            )),
            detectionOrder: 1
        )
        let textData = Data("restorable text".utf8)
        let textEntry = HistoryEntry(content: .text(textData), detectionOrder: 0)
        let pasteboard = HistoryPickerWritablePasteboard()
        var dismissCount = 0
        let restorer = ClipboardRestorer(pasteboard: pasteboard)
        let model = HistoryPickerModel(
            entries: [missingEntry, textEntry],
            onConfirm: { try restorer.restore($0) },
            onDismiss: { dismissCount += 1 }
        )

        model.confirm(missingEntry)
        XCTAssertNotNil(model.restorationErrorMessage)

        model.confirm(textEntry)

        XCTAssertNil(model.restorationErrorMessage)
        XCTAssertEqual(dismissCount, 1)
        XCTAssertEqual(
            pasteboard.dataByType[ClipboardContentSelector.plainTextType],
            textData
        )
        XCTAssertEqual(
            pasteboard.dataByType[ClipboardContentSelector.restoredType],
            Data()
        )
    }

    func testEmptyHistoryHasNoSelectionOrConfirmation() {
        var didConfirm = false
        let model = HistoryPickerModel(entries: [], onConfirm: { _ in didConfirm = true })

        model.moveSelection(by: 1)
        model.confirmSelection()

        XCTAssertNil(model.selectedID)
        XCTAssertFalse(didConfirm)
    }

    func testPickerHeightShrinksForEmptyAndShortHistoriesAndKeepsItsWidth() {
        let emptyModel = HistoryPickerModel()
        let oneEntryModel = HistoryPickerModel(entries: [
            HistoryEntry(content: .text(Data("only entry".utf8)), detectionOrder: 0)
        ])

        let emptySize = HistoryPickerLayout.contentSize(for: emptyModel)
        let oneEntrySize = HistoryPickerLayout.contentSize(for: oneEntryModel)

        XCTAssertEqual(emptySize.width, 420)
        XCTAssertEqual(oneEntrySize.width, 420)
        XCTAssertLessThan(emptySize.height, 480)
        XCTAssertLessThan(oneEntrySize.height, 480)
    }

    func testPickerHeightStopsAtMaximumWhenRowsNeedScrolling() {
        let entries = (0..<20).map { index in
            HistoryEntry(
                content: .text(Data("entry \(index)".utf8)),
                detectionOrder: UInt64(index)
            )
        }
        let model = HistoryPickerModel(entries: entries)

        XCTAssertEqual(HistoryPickerLayout.contentSize(for: model).height, 480)
    }

    func testControllerResizesPanelFromCurrentStoreContentsBeforeShowing() {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let imageService = ImageIngestionService(
            destinationSaver: ImageFolderSaver(
                destinationDirectory: temporaryDirectory.appendingPathComponent("destination")
            ),
            fallbackSaver: ImageFolderSaver(
                destinationDirectory: temporaryDirectory.appendingPathComponent("fallback")
            ),
            notifier: HistoryPickerSilentNotifier()
        )
        let store = HistoryStore(imageIngestionService: imageService)
        store.recordDetection(of: .text(data: Data("only entry".utf8)))
        let controller = HistoryPickerController(historyStore: store)

        controller.show()
        defer { controller.dismiss() }

        XCTAssertEqual(controller.contentSize.width, 420, accuracy: 0.5)
        XCTAssertLessThan(controller.contentSize.height, 480)
        XCTAssertEqual(
            controller.contentSize.height,
            HistoryPickerLayout.contentSize(for: HistoryPickerModel(entries: store.entries)).height,
            accuracy: 0.5
        )
    }

    func testControllerCapturesPasteTargetImmediatelyBeforeShowingPicker() {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = HistoryStore(imageIngestionService: ImageIngestionService(
            destinationSaver: ImageFolderSaver(
                destinationDirectory: temporaryDirectory.appendingPathComponent("destination")
            ),
            fallbackSaver: ImageFolderSaver(
                destinationDirectory: temporaryDirectory.appendingPathComponent("fallback")
            ),
            notifier: HistoryPickerSilentNotifier()
        ))
        let targetProvider = HistoryPickerTargetProvider()
        let autoPasteController = AutoPasteController(
            targetApplicationProvider: targetProvider
        )
        let controller = HistoryPickerController(
            historyStore: store,
            autoPasteController: autoPasteController
        )

        XCTAssertEqual(targetProvider.captureCount, 0)
        controller.show()
        defer { controller.dismiss() }

        XCTAssertEqual(targetProvider.captureCount, 1)
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

    func testPickerUsesPrecomputedThumbnailWithoutReadingSavedFile() {
        let thumbnail = NSImage(size: NSSize(width: 32, height: 16))
        let entry = HistoryEntry(
            content: .image(ImageHistoryEntry(
                fileURL: URL(fileURLWithPath: "/tmp/removed-snapspool-image.png"),
                isFallback: false,
                thumbnail: thumbnail
            )),
            detectionOrder: 0
        )

        let model = HistoryPickerModel(entries: [entry])

        XCTAssertTrue(model.thumbnails[entry.id] === thumbnail)
    }
}

private struct HistoryPickerSilentNotifier: ImageSaveNotifying {
    func notifyDestinationSaveFailed() {}
    func notifyFallbackSaveFailed() {}
}

@MainActor
private final class HistoryPickerWritablePasteboard: ClipboardPasteboardWriting {
    private(set) var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
    private(set) var replaceCallCount = 0

    func replaceContents(with representations: [PasteboardRepresentation]) -> Bool {
        replaceCallCount += 1
        dataByType = Dictionary(uniqueKeysWithValues: representations.map { ($0.type, $0.data) })
        return true
    }
}

@MainActor
private final class HistoryPickerTargetProvider: PasteTargetApplicationProviding {
    private(set) var captureCount = 0

    func frontmostApplication() -> (any PasteTargetApplication)? {
        captureCount += 1
        return nil
    }
}
