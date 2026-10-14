import AppKit
import XCTest
@testable import Snapspool

@MainActor
final class HistoryStoreTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var imageService: ImageIngestionService!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = temporaryDirectory.appendingPathComponent("destination")
        let fallback = temporaryDirectory.appendingPathComponent("fallback")
        imageService = ImageIngestionService(
            destinationSaver: ImageFolderSaver(destinationDirectory: destination),
            fallbackSaver: ImageFolderSaver(destinationDirectory: fallback),
            notifier: SilentNotifier()
        )
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: temporaryDirectory.path) {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testDefaultsAndConfiguredLimitsAreClampedToAllowedRange() {
        let defaults = HistoryStore(imageIngestionService: imageService)
        XCTAssertEqual(defaults.imageLimit, 30)
        XCTAssertEqual(defaults.textLimit, 30)

        let clamped = HistoryStore(
            imageLimit: 1,
            textLimit: 1_000,
            imageIngestionService: imageService
        )
        XCTAssertEqual(clamped.imageLimit, 10)
        XCTAssertEqual(clamped.textLimit, 100)
    }

    func testImageAndTextLimitsEvictOnlyOldestEntryOfMatchingKind() async throws {
        let store = HistoryStore(imageLimit: 10, textLimit: 10, imageIngestionService: imageService)
        for index in 0..<11 {
            store.ingest(.text(data: Data("text-\(index)".utf8)))
        }
        for _ in 0..<11 {
            await store.ingest(try imageContent())?.value
        }

        XCTAssertEqual(store.textCount, 10)
        XCTAssertEqual(store.imageCount, 10)
        XCTAssertFalse(textValues(in: store).contains("text-0"))
        XCTAssertTrue(textValues(in: store).contains("text-1"))
    }

    func testReducingLimitsImmediatelyRemovesOldestMatchingEntries() async throws {
        let store = HistoryStore(imageLimit: 20, textLimit: 20, imageIngestionService: imageService)
        for index in 0..<12 {
            store.ingest(.text(data: Data("text-\(index)".utf8)))
            await store.ingest(try imageContent())?.value
        }

        store.setTextLimit(10)
        let imageRemovalTask = store.setImageLimit(10)
        await imageRemovalTask?.value

        XCTAssertEqual(store.textCount, 10)
        XCTAssertEqual(store.imageCount, 10)
        let serviceEntryCount = await imageService.entries.count
        XCTAssertEqual(serviceEntryCount, 10)
        XCTAssertFalse(textValues(in: store).contains("text-0"))
        XCTAssertFalse(textValues(in: store).contains("text-1"))
    }

    func testDuplicateTextMovesExistingEntryToFrontWithoutIncreasingCount() {
        let store = HistoryStore(imageIngestionService: imageService)
        store.ingest(.text(data: Data("same".utf8)))
        let originalID = store.entries[0].id
        store.ingest(.text(data: Data("other".utf8)))
        store.ingest(.text(data: Data("same".utf8)))

        XCTAssertEqual(store.textCount, 2)
        XCTAssertEqual(store.entries[0].id, originalID)
        XCTAssertEqual(textValues(in: store), ["same", "other"])
    }

    func testImagesAreNotDeduplicated() async throws {
        let store = HistoryStore(imageIngestionService: imageService)
        let content = try imageContent()
        await store.ingest(content)?.value
        await store.ingest(content)?.value
        XCTAssertEqual(store.imageCount, 2)
    }

    func testLateImageCompletionKeepsDetectionOrder() async throws {
        let store = HistoryStore(imageIngestionService: imageService)
        let image = try imageContent()
        let pending = try XCTUnwrap(store.recordDetection(of: image))
        store.ingest(.text(data: Data("newer".utf8)))

        store.completeImageDetection(pending, with: await imageService.ingest(image))

        XCTAssertEqual(store.entries.count, 2)
        guard case .text = store.entries[0].content,
              case .image = store.entries[1].content else {
            return XCTFail("Entries must remain ordered by clipboard detection")
        }
    }

    func testAsyncImageIngestionKeepsDetectionOrderWhileMainActorHandlesNewerText() async throws {
        let store = HistoryStore(imageIngestionService: imageService)

        let imageTask = try XCTUnwrap(store.ingest(try imageContent()))
        store.ingest(.text(data: Data("newer".utf8)))
        await imageTask.value

        XCTAssertEqual(store.entries.count, 2)
        guard case .text = store.entries[0].content,
              case .image = store.entries[1].content else {
            return XCTFail("Async completion must not replace clipboard detection order")
        }
    }

    func testImageHistoryKeepsOnlyFileReferenceNotOriginalClipboardBytes() async throws {
        let store = HistoryStore(imageIngestionService: imageService)
        await store.ingest(try imageContent())?.value

        guard case let .image(entry) = try XCTUnwrap(store.entries.first).content else {
            return XCTFail("Expected image history")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.fileURL.path))
        XCTAssertGreaterThan(try entry.restorationPNGData().count, 0)
    }

    func testARecreatedStoreStartsEmpty() {
        var store: HistoryStore? = HistoryStore(imageIngestionService: imageService)
        store?.ingest(.text(data: Data("temporary".utf8)))
        XCTAssertEqual(store?.textCount, 1)

        store = HistoryStore(imageIngestionService: imageService)
        XCTAssertTrue(store?.entries.isEmpty == true)
    }

    private func textValues(in store: HistoryStore) -> [String] {
        store.entries.compactMap { entry in
            guard case let .text(data) = entry.content else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    private func imageContent() throws -> ClipboardContent {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        return .image(data: data, type: ClipboardContentSelector.pngType)
    }
}

private final class SilentNotifier: ImageSaveNotifying, @unchecked Sendable {
    func notifyDestinationSaveFailed() {}
    func notifyFallbackSaveFailed() {}
}
