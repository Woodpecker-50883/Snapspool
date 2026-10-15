import AppKit
import UserNotifications
import XCTest
@testable import Snapspool

final class ImageIngestionServiceTests: XCTestCase {
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
        if let temporaryDirectory,
           FileManager.default.fileExists(atPath: temporaryDirectory.path) {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testFallbackDirectoryIsInsideApplicationSupport() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        XCTAssertEqual(
            ImageIngestionService.defaultFallbackDirectory(),
            applicationSupport
                .appendingPathComponent("Snapspool", isDirectory: true)
                .appendingPathComponent("fallback", isDirectory: true)
        )
    }

    func testCreatingServiceRemovesFallbackFilesOrphanedByPreviousLaunch() throws {
        let destination = try directoryURL(named: "destination", blocked: false)
        let fallback = try directoryURL(named: "fallback", blocked: false)
        try FileManager.default.createDirectory(
            at: fallback,
            withIntermediateDirectories: true
        )
        let orphanedFile = fallback.appendingPathComponent("orphaned.png")
        try Data("previous launch".utf8).write(to: orphanedFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanedFile.path))

        _ = ImageIngestionService(
            destinationSaver: ImageFolderSaver(destinationDirectory: destination),
            fallbackSaver: ImageFolderSaver(destinationDirectory: fallback),
            notifier: NotificationSpy()
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanedFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fallback.path))
    }

    func testDestinationFailureStoresRestorableFallbackAndNotifies() async throws {
        let notifier = NotificationSpy()
        let service = try makeService(
            destinationBlocked: true,
            fallbackBlocked: false,
            notifier: notifier
        )

        let ingestedEntry = await service.ingest(try imageContent())
        let entry = try XCTUnwrap(ingestedEntry)
        let entries = await service.entries

        XCTAssertTrue(entry.isFallback)
        XCTAssertEqual(entries, [entry])
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.fileURL.path))
        XCTAssertEqual(try entry.restorationPNGData(), try Data(contentsOf: entry.fileURL))
        XCTAssertEqual(notifier.destinationFailures, 1)
        XCTAssertEqual(notifier.fallbackFailures, 0)
    }

    func testFallbackFailureDoesNotAddHistoryAndNotifies() async throws {
        let notifier = NotificationSpy()
        let service = try makeService(
            destinationBlocked: true,
            fallbackBlocked: true,
            notifier: notifier
        )

        let entry = await service.ingest(try imageContent())
        let entries = await service.entries
        XCTAssertNil(entry)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(notifier.destinationFailures, 0)
        XCTAssertEqual(notifier.fallbackFailures, 1)
    }

    func testRemovingFallbackHistoryDeletesFallbackFile() async throws {
        let service = try makeService(
            destinationBlocked: true,
            fallbackBlocked: false,
            notifier: NotificationSpy()
        )
        let ingestedEntry = await service.ingest(try imageContent())
        let entry = try XCTUnwrap(ingestedEntry)

        await service.remove(entry)

        let entries = await service.entries
        XCTAssertTrue(entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.fileURL.path))
    }

    func testRemovingFallbackHistoryDeletesOnlyItsCorrespondingFile() async throws {
        let service = try makeService(
            destinationBlocked: true,
            fallbackBlocked: false,
            notifier: NotificationSpy()
        )
        let firstResult = await service.ingest(try imageContent())
        let secondResult = await service.ingest(try imageContent())
        let first = try XCTUnwrap(firstResult)
        let second = try XCTUnwrap(secondResult)
        XCTAssertNotEqual(first.fileURL, second.fileURL)

        await service.remove(first)

        let entries = await service.entries
        XCTAssertEqual(entries, [second])
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.fileURL.path))
    }

    func testRemovingNormallySavedHistoryKeepsArchivedImageFile() async throws {
        let notifier = NotificationSpy()
        let service = try makeService(
            destinationBlocked: false,
            fallbackBlocked: false,
            notifier: notifier
        )
        let ingestedEntry = await service.ingest(try imageContent())
        let entry = try XCTUnwrap(ingestedEntry)

        await service.remove(entry)

        let entries = await service.entries
        XCTAssertTrue(entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.fileURL.path))
        XCTAssertEqual(notifier.destinationFailures, 0)
        XCTAssertEqual(notifier.fallbackFailures, 0)
    }

    func testProductionNotifierBuildsRequestsForBothFailureKinds() throws {
        let recorder = NotificationRequestRecorder()
        let notifier = UserNotificationImageSaveNotifier { recorder.append($0) }

        notifier.notifyDestinationSaveFailed()
        notifier.notifyFallbackSaveFailed()

        let requests = recorder.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map(\.content.title), ["Snapspool", "Snapspool"])
        XCTAssertTrue(requests[0].identifier.hasPrefix("image-save-fallback-"))
        XCTAssertEqual(requests[0].content.body, L10n.string("notification.destination-save-failed"))
        XCTAssertTrue(requests[1].identifier.hasPrefix("image-save-failed-"))
        XCTAssertEqual(requests[1].content.body, L10n.string("notification.fallback-save-failed"))
        XCTAssertNil(requests[0].trigger)
        XCTAssertNil(requests[1].trigger)
    }

    func testTextIsNotSavedOrAddedToImageHistory() async throws {
        let notifier = NotificationSpy()
        let service = try makeService(
            destinationBlocked: false,
            fallbackBlocked: false,
            notifier: notifier
        )

        let entry = await service.ingest(.text(data: Data("text".utf8)))
        let entries = await service.entries
        XCTAssertNil(entry)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(notifier.destinationFailures, 0)
        XCTAssertEqual(notifier.fallbackFailures, 0)
    }

    func testPNGEncodingFileWritingAndThumbnailGenerationRunOffTheMainThread() async throws {
        let saveObservation = ThreadObservation()
        let thumbnailObservation = ThreadObservation()
        let destination = try directoryURL(named: "destination", blocked: false)
        let fallback = try directoryURL(named: "fallback", blocked: false)
        let service = ImageIngestionService(
            destinationSaver: ImageFolderSaver(
                destinationDirectory: destination,
                willSave: { saveObservation.recordCurrentThread() }
            ),
            fallbackSaver: ImageFolderSaver(destinationDirectory: fallback),
            notifier: NotificationSpy(),
            thumbnailGenerator: HistoryThumbnailGenerator(
                willGenerate: { thumbnailObservation.recordCurrentThread() }
            )
        )

        let entry = await service.ingest(try imageContent())

        XCTAssertNotNil(entry?.thumbnail)
        XCTAssertEqual(saveObservation.wasMainThread, false)
        XCTAssertEqual(thumbnailObservation.wasMainThread, false)
    }

    private func makeService(
        destinationBlocked: Bool,
        fallbackBlocked: Bool,
        notifier: NotificationSpy
    ) throws -> ImageIngestionService {
        let destination = try directoryURL(named: "destination", blocked: destinationBlocked)
        let fallback = try directoryURL(named: "fallback", blocked: fallbackBlocked)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return ImageIngestionService(
            destinationSaver: ImageFolderSaver(destinationDirectory: destination, now: { date }),
            fallbackSaver: ImageFolderSaver(destinationDirectory: fallback, now: { date }),
            notifier: notifier
        )
    }

    private func directoryURL(named name: String, blocked: Bool) throws -> URL {
        let parent = temporaryDirectory.appendingPathComponent("\(name)-parent")
        if blocked {
            try Data("not a directory".utf8).write(to: parent)
        }
        return parent.appendingPathComponent(name, isDirectory: true)
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

private final class NotificationSpy: ImageSaveNotifying, @unchecked Sendable {
    private(set) var destinationFailures = 0
    private(set) var fallbackFailures = 0

    func notifyDestinationSaveFailed() {
        destinationFailures += 1
    }

    func notifyFallbackSaveFailed() {
        fallbackFailures += 1
    }
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

private final class NotificationRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [UNNotificationRequest] = []

    var requests: [UNNotificationRequest] {
        lock.withLock { recordedRequests }
    }

    func append(_ request: UNNotificationRequest) {
        lock.withLock { recordedRequests.append(request) }
    }
}
