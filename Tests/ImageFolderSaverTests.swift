import AppKit
import XCTest
@testable import Snapspool

final class ImageFolderSaverTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory,
           FileManager.default.fileExists(atPath: temporaryDirectory.path) {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testDefaultDestinationIsPicturesSnapspoolUnderHomeDirectory() {
        let pictures = FileManager.default.urls(
            for: .picturesDirectory,
            in: .userDomainMask
        ).first!

        XCTAssertEqual(
            ImageFolderSaver.defaultDestinationDirectory(),
            pictures.appendingPathComponent("Snapspool", isDirectory: true)
        )
    }

    func testCreatesMissingDestinationWithoutRequestingUserSelection() throws {
        let saver = makeSaver()
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryDirectory.path))

        let savedURL = try XCTUnwrap(try saver.save(.image(
            data: try imageData(type: .png),
            type: ClipboardContentSelector.pngType
        )))

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: temporaryDirectory.path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path))
    }

    func testConvertsPNGJPEGAndTIFFInputsToPNGFiles() throws {
        let inputTypes: [(NSBitmapImageRep.FileType, NSPasteboard.PasteboardType)] = [
            (.png, ClipboardContentSelector.pngType),
            (.jpeg, ClipboardContentSelector.jpegType),
            (.tiff, ClipboardContentSelector.tiffType),
        ]

        for (index, input) in inputTypes.enumerated() {
            let saver = makeSaver(secondOffset: index)
            let savedURL = try XCTUnwrap(try saver.save(.image(
                data: try imageData(type: input.0),
                type: input.1
            )))
            let savedData = try Data(contentsOf: savedURL)

            XCTAssertEqual(Array(savedData.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
            XCTAssertNotNil(NSBitmapImageRep(data: savedData))
        }
    }

    func testUsesTimestampAndAddsSequenceWithoutOverwritingExistingFiles() throws {
        let saver = makeSaver()
        let image = ClipboardContent.image(
            data: try imageData(type: .png),
            type: ClipboardContentSelector.pngType
        )

        let firstURL = try XCTUnwrap(try saver.save(image))
        let firstData = try Data(contentsOf: firstURL)
        let secondURL = try XCTUnwrap(try saver.save(image))
        let thirdURL = try XCTUnwrap(try saver.save(image))

        XCTAssertEqual(firstURL.lastPathComponent, "20260405-060708.png")
        XCTAssertEqual(secondURL.lastPathComponent, "20260405-060708-02.png")
        XCTAssertEqual(thirdURL.lastPathComponent, "20260405-060708-03.png")
        XCTAssertEqual(try Data(contentsOf: firstURL), firstData)
    }

    func testDoesNotCreateDirectoryOrFileForText() throws {
        let savedURL = try makeSaver().save(.text(data: Data("not saved".utf8)))

        XCTAssertNil(savedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryDirectory.path))
    }

    private func makeSaver(secondOffset: Int = 0) -> ImageFolderSaver {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(
            from: DateComponents(
                year: 2026,
                month: 4,
                day: 5,
                hour: 6,
                minute: 7,
                second: 8 + secondOffset
            )
        )!
        return ImageFolderSaver(
            destinationDirectory: temporaryDirectory,
            now: { date },
            calendar: calendar
        )
    }

    private func imageData(type: NSBitmapImageRep.FileType) throws -> Data {
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
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
            )
        )
        bitmap.setColor(
            NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1),
            atX: 0,
            y: 0
        )
        return try XCTUnwrap(bitmap.representation(using: type, properties: [:]))
    }
}
