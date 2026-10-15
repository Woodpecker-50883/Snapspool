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
        var textIDs: [UUID] = []
        var imageIDs: [UUID] = []
        for index in 0..<11 {
            store.ingest(.text(data: Data("text-\(index)".utf8)))
            textIDs.append(try XCTUnwrap(store.entries.first {
                if case let .text(data) = $0.content {
                    return data == Data("text-\(index)".utf8)
                }
                return false
            }).id)

            await store.ingest(try imageContent())?.value
            imageIDs.append(try XCTUnwrap(store.entries.first {
                if case .image = $0.content { return true }
                return false
            }).id)
        }

        XCTAssertEqual(store.textCount, 10)
        XCTAssertEqual(store.imageCount, 10)
        let remainingIDs = Set(store.entries.map(\.id))
        XCTAssertFalse(remainingIDs.contains(textIDs[0]), "The oldest text must be evicted")
        XCTAssertTrue(remainingIDs.contains(textIDs[1]), "A newer text must remain")
        XCTAssertFalse(remainingIDs.contains(imageIDs[0]), "The oldest image must be evicted")
        XCTAssertTrue(remainingIDs.contains(imageIDs[1]), "A newer image must remain")
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

    func testImagesKeepDetectionOrderWhenSavingCompletesInDetectionOrder() async throws {
        try await assertImageDetectionOrder(completionOrder: [0, 1])
    }

    func testImagesKeepDetectionOrderWhenSavingCompletesInReverseOrder() async throws {
        try await assertImageDetectionOrder(completionOrder: [1, 0])
    }

    func testAsyncImageIngestionKeepsDetectionOrderWhileMainActorHandlesNewerText() async throws {
        let encodingThread = ThreadObservation()
        let writingThread = ThreadObservation()
        let thumbnailThread = ThreadObservation()
        let encodingStarted = expectation(description: "PNG encoding started")
        let allowEncoding = DispatchSemaphore(value: 0)
        let destination = temporaryDirectory.appendingPathComponent("observed-destination")
        let fallback = temporaryDirectory.appendingPathComponent("observed-fallback")
        let service = ImageIngestionService(
            destinationSaver: ImageFolderSaver(
                destinationDirectory: destination,
                willEncodePNG: {
                    encodingThread.recordCurrentThread()
                    encodingStarted.fulfill()
                    _ = allowEncoding.wait(timeout: .now() + 1)
                },
                willWriteFile: { writingThread.recordCurrentThread() }
            ),
            fallbackSaver: ImageFolderSaver(destinationDirectory: fallback),
            notifier: SilentNotifier(),
            thumbnailGenerator: HistoryThumbnailGenerator(
                willGenerate: { thumbnailThread.recordCurrentThread() }
            )
        )
        let store = HistoryStore(imageIngestionService: service)

        let callStarted = ProcessInfo.processInfo.systemUptime
        let imageTask = try XCTUnwrap(store.ingest(try imageContent()))
        let callDuration = ProcessInfo.processInfo.systemUptime - callStarted

        XCTAssertLessThan(
            callDuration,
            0.2,
            "Image ingestion must return without waiting for background processing"
        )
        XCTAssertEqual(store.imageCount, 0)
        await fulfillment(of: [encodingStarted], timeout: 1)
        store.ingest(.text(data: Data("newer".utf8)))
        XCTAssertEqual(store.textCount, 1, "The main actor must remain responsive during encoding")
        allowEncoding.signal()
        await imageTask.value

        XCTAssertEqual(encodingThread.wasMainThread, false)
        XCTAssertEqual(writingThread.wasMainThread, false)
        XCTAssertEqual(thumbnailThread.wasMainThread, false)
        XCTAssertEqual(store.entries.count, 2)
        guard case .text = store.entries[0].content,
              case .image = store.entries[1].content else {
            return XCTFail("Async completion must not replace clipboard detection order")
        }
    }

    func testImageHistoryCannotRestoreAfterItsSavedFileIsRemoved() async throws {
        let store = HistoryStore(imageIngestionService: imageService)
        await store.ingest(try imageContent())?.value

        guard case let .image(entry) = try XCTUnwrap(store.entries.first).content else {
            return XCTFail("Expected image history")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.fileURL.path))
        try FileManager.default.removeItem(at: entry.fileURL)

        XCTAssertThrowsError(try entry.restorationPNGData(), "Original bytes must not be cached in memory")
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

    private func assertImageDetectionOrder(completionOrder: [Int]) async throws {
        let store = HistoryStore(imageIngestionService: imageService)
        let contents = try [imageContent(red: 1, blue: 0), imageContent(red: 0, blue: 1)]
        let pending = try contents.map { try XCTUnwrap(store.recordDetection(of: $0)) }
        var saved: [ImageHistoryEntry] = []
        for content in contents {
            let result = await imageService.ingest(content)
            saved.append(try XCTUnwrap(result))
        }

        for index in completionOrder {
            store.completeImageDetection(pending[index], with: saved[index])
        }

        let actual = store.entries.compactMap { entry -> ImageHistoryEntry? in
            guard case let .image(image) = entry.content else { return nil }
            return image
        }
        XCTAssertEqual(actual, [saved[1], saved[0]])
    }

    private func imageContent(red: CGFloat, blue: CGFloat) throws -> ClipboardContent {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.setColor(NSColor(deviceRed: red, green: 0, blue: blue, alpha: 1), atX: 0, y: 0)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        return .image(data: data, type: ClipboardContentSelector.pngType)
    }
}

private final class SilentNotifier: ImageSaveNotifying, @unchecked Sendable {
    func notifyDestinationSaveFailed() {}
    func notifyFallbackSaveFailed() {}
}

private final class ThreadObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    var wasMainThread: Bool? {
        lock.withLock { value }
    }

    func recordCurrentThread() {
        lock.withLock { value = Thread.isMainThread }
    }
}
