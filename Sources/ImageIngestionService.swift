import Foundation
import UserNotifications

protocol ImageSaveNotifying {
    func notifyDestinationSaveFailed()
    func notifyFallbackSaveFailed()
}

final class UserNotificationImageSaveNotifier: ImageSaveNotifying {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        center.requestAuthorization(options: [.alert]) { _, _ in }
    }

    func notifyDestinationSaveFailed() {
        deliver(
            identifier: "image-save-fallback-\(UUID().uuidString)",
            title: "Snapspool",
            body: "画像を保存先へ書き込めなかったため、履歴用の退避領域に保存しました。"
        )
    }

    func notifyFallbackSaveFailed() {
        deliver(
            identifier: "image-save-failed-\(UUID().uuidString)",
            title: "Snapspool",
            body: "画像を保存できなかったため、履歴には追加されませんでした。"
        )
    }

    private func deliver(identifier: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        ))
    }
}

struct ImageHistoryEntry: Identifiable, Equatable {
    let id: UUID
    let fileURL: URL
    let isFallback: Bool

    init(id: UUID = UUID(), fileURL: URL, isFallback: Bool) {
        self.id = id
        self.fileURL = fileURL
        self.isFallback = isFallback
    }

    /// Reads the exact PNG kept for this history entry, ready for pasteboard restoration.
    func restorationPNGData() throws -> Data {
        try Data(contentsOf: fileURL)
    }
}

final class ImageIngestionService {
    private let destinationSaver: ImageFolderSaver
    private let fallbackSaver: ImageFolderSaver
    private let notifier: any ImageSaveNotifying
    private let fileManager: FileManager

    private(set) var entries: [ImageHistoryEntry] = []

    init(
        destinationSaver: ImageFolderSaver = ImageFolderSaver(),
        fallbackSaver: ImageFolderSaver = ImageFolderSaver(
            destinationDirectory: ImageIngestionService.defaultFallbackDirectory()
        ),
        notifier: any ImageSaveNotifying = UserNotificationImageSaveNotifier(),
        fileManager: FileManager = .default
    ) {
        self.destinationSaver = destinationSaver
        self.fallbackSaver = fallbackSaver
        self.notifier = notifier
        self.fileManager = fileManager
    }

    static func defaultFallbackDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("Snapspool", isDirectory: true)
            .appendingPathComponent("fallback", isDirectory: true)
    }

    @discardableResult
    func ingest(_ content: ClipboardContent) -> ImageHistoryEntry? {
        guard case .image = content else { return nil }

        do {
            guard let fileURL = try destinationSaver.save(content) else { return nil }
            let entry = ImageHistoryEntry(fileURL: fileURL, isFallback: false)
            entries.insert(entry, at: 0)
            return entry
        } catch {
            do {
                guard let fileURL = try fallbackSaver.save(content) else { return nil }
                let entry = ImageHistoryEntry(fileURL: fileURL, isFallback: true)
                entries.insert(entry, at: 0)
                notifier.notifyDestinationSaveFailed()
                return entry
            } catch {
                notifier.notifyFallbackSaveFailed()
                return nil
            }
        }
    }

    func remove(_ entry: ImageHistoryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let removed = entries.remove(at: index)
        if removed.isFallback {
            try? fileManager.removeItem(at: removed.fileURL)
        }
    }
}
