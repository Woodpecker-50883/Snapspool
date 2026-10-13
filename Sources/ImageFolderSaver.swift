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
    private let calendar: Calendar

    init(
        destinationDirectory: URL = Self.defaultDestinationDirectory(),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.destinationDirectory = destinationDirectory
        self.fileManager = fileManager
        self.now = now
        self.calendar = calendar
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
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let stem = String(
            format: "%04d%02d%02d-%02d%02d%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0
        )

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
