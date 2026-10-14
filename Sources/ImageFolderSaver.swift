import AppKit
import Foundation

enum ImageFolderSaverError: Error {
    case invalidImageData
    case pngEncodingFailed
}

struct ImageFolderSaver {
    private let destinationDirectory: URL
    private let fileManager: FileManager
    private let now: () -> Date
    private let namingTimeZone: TimeZone

    init(
        destinationDirectory: URL = Self.defaultDestinationDirectory(),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.destinationDirectory = destinationDirectory
        self.fileManager = fileManager
        self.now = now
        self.namingTimeZone = calendar.timeZone
    }

    static func defaultDestinationDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        let picturesDirectory = fileManager.urls(
            for: .picturesDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures", isDirectory: true)
        return picturesDirectory
            .appendingPathComponent("Snapspool", isDirectory: true)
    }

    /// Saves image clipboard content as PNG. Text content deliberately produces no file.
    @discardableResult
    func save(_ content: ClipboardContent) throws -> URL? {
        guard case let .image(data, _) = content else { return nil }

        guard let bitmap = NSBitmapImageRep(data: data) else {
            throw ImageFolderSaverError.invalidImageData
        }
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw ImageFolderSaverError.pngEncodingFailed
        }

        try fileManager.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )

        let fileURL = nextAvailableFileURL(for: now())
        try pngData.write(to: fileURL, options: .withoutOverwriting)
        return fileURL
    }

    private func nextAvailableFileURL(for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = namingTimeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = formatter.string(from: date)

        var sequence = 1
        while true {
            let suffix = sequence == 1 ? "" : String(format: "-%02d", sequence)
            let candidate = destinationDirectory
                .appendingPathComponent("\(stem)\(suffix)")
                .appendingPathExtension("png")
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            sequence += 1
        }
    }
}
