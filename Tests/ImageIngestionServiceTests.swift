import AppKit
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

    func testDestinationFailureStoresRestorableFallbackAndNotifies() throws {
        let notifier = NotificationSpy()
        let service = try makeService(
            destinationBlocked: true,
            fallbackBlocked: false,
            notifier: notifier
        )

        let entry = try XCTUnwrap(service.ingest(try imageContent()))

        XCTAssertTrue(entry.isFallback)
        XCTAssertEqual(service.entries, [entry])
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.fileURL.path))
        XCTAssertEqual(try entry.restorationPNGData(), try Data(contentsOf: entry.fileURL))
        XCTAssertEqual(notifier.destinationFailures, 1)
        XCTAssertEqual(notifier.fallbackFailures, 0)
    }

    func testFallbackFailureDoesNotAddHistoryAndNotifies() throws {
        let notifier = NotificationSpy()
        let service = try makeService(
            destinationBlocked: true,
            fallbackBlocked: true,
            notifier: notifier
        )

        XCTAssertNil(service.ingest(try imageContent()))
        XCTAssertTrue(service.entries.isEmpty)
        XCTAssertEqual(notifier.destinationFailures, 0)
        XCTAssertEqual(notifier.fallbackFailures, 1)
    }

    func testRemovingFallbackHistoryDeletesFallbackFile() throws {
        let service = try makeService(
            destinationBlocked: true,
            fallbackBlocked: false,
            notifier: NotificationSpy()
        )
        let entry = try XCTUnwrap(service.ingest(try imageContent()))

        service.remove(entry)

        XCTAssertTrue(service.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.fileURL.path))
    }

    func testRemovingNormallySavedHistoryKeepsArchivedImageFile() throws {
        let service = try makeService(
            destinationBlocked: false,
            fallbackBlocked: false,
            notifier: NotificationSpy()
        )
        let entry = try XCTUnwrap(service.ingest(try imageContent()))

        service.remove(entry)

        XCTAssertTrue(service.entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.fileURL.path))
    }

    func testTextIsNotSavedOrAddedToImageHistory() throws {
        let notifier = NotificationSpy()
        let service = try makeService(
            destinationBlocked: false,
            fallbackBlocked: false,
            notifier: notifier
        )

        XCTAssertNil(service.ingest(.text(data: Data("text".utf8))))
        XCTAssertTrue(service.entries.isEmpty)
        XCTAssertEqual(notifier.destinationFailures, 0)
        XCTAssertEqual(notifier.fallbackFailures, 0)
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

private final class NotificationSpy: ImageSaveNotifying {
    private(set) var destinationFailures = 0
    private(set) var fallbackFailures = 0

    func notifyDestinationSaveFailed() {
        destinationFailures += 1
    }

    func notifyFallbackSaveFailed() {
        fallbackFailures += 1
    }
}
