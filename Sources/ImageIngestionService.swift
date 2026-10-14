import Foundation
import UserNotifications

protocol ImageSaveNotifying: Sendable {
    func notifyDestinationSaveFailed()
    func notifyFallbackSaveFailed()
}

final class UserNotificationImageSaveNotifier: ImageSaveNotifying, @unchecked Sendable {
    private let addRequest: (UNNotificationRequest) -> Void
    private let localize: (String) -> String

    init(
        center: UNUserNotificationCenter = .current(),
        localize: @escaping (String) -> String = { L10n.string($0) }
    ) {
        self.addRequest = { request in
            center.add(request)
        }
        self.localize = localize
        center.requestAuthorization(options: [.alert]) { _, _ in }
    }

    /// Keeps notification formatting testable without delivering a real user notification.
    init(
        addRequest: @escaping (UNNotificationRequest) -> Void,
        localize: @escaping (String) -> String = { L10n.string($0) }
    ) {
        self.addRequest = addRequest
        self.localize = localize
    }

    func notifyDestinationSaveFailed() {
        deliver(
            identifier: "image-save-fallback-\(UUID().uuidString)",
            title: "Snapspool",
            body: localize("notification.destination-save-failed")
        )
    }

    func notifyFallbackSaveFailed() {
        deliver(
            identifier: "image-save-failed-\(UUID().uuidString)",
            title: "Snapspool",
            body: localize("notification.fallback-save-failed")
        )
    }

    private func deliver(identifier: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        addRequest(UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        ))
    }
}

struct ImageHistoryEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let fileURL: URL
    let isFallback: Bool
    let accessLease: SecurityScopedAccessLease?

    init(
        id: UUID = UUID(),
        fileURL: URL,
        isFallback: Bool,
        accessLease: SecurityScopedAccessLease? = nil
    ) {
        self.id = id
        self.fileURL = fileURL
        self.isFallback = isFallback
        self.accessLease = accessLease
    }

    static func == (lhs: ImageHistoryEntry, rhs: ImageHistoryEntry) -> Bool {
        lhs.id == rhs.id && lhs.fileURL == rhs.fileURL && lhs.isFallback == rhs.isFallback
    }

    /// Reads the exact PNG kept for this history entry, ready for pasteboard restoration.
    func restorationPNGData() throws -> Data {
        try Data(contentsOf: fileURL)
    }
}

actor ImageIngestionService {
    private let destination: @Sendable () -> ImageDestinationSnapshot
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
        self.destination = {
            ImageDestinationSnapshot(saver: destinationSaver, accessLease: nil)
        }
        self.fallbackSaver = fallbackSaver
        self.notifier = notifier
        self.fileManager = fileManager
        Self.removeOrphanedFallbackFiles(
            in: fallbackSaver.destinationURL,
            fileManager: fileManager
        )
    }

    init(
        destinationProvider: @escaping @Sendable () -> ImageDestinationSnapshot,
        fallbackSaver: ImageFolderSaver = ImageFolderSaver(
            destinationDirectory: ImageIngestionService.defaultFallbackDirectory()
        ),
        notifier: any ImageSaveNotifying = UserNotificationImageSaveNotifier(),
        fileManager: FileManager = .default
    ) {
        self.destination = destinationProvider
        self.fallbackSaver = fallbackSaver
        self.notifier = notifier
        self.fileManager = fileManager
        Self.removeOrphanedFallbackFiles(
            in: fallbackSaver.destinationURL,
            fileManager: fileManager
        )
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

    /// History is intentionally memory-only, so every fallback file left from a
    /// previous process is orphaned when a new service is created.
    private static func removeOrphanedFallbackFiles(
        in directory: URL,
        fileManager: FileManager
    ) {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }

        for item in contents {
            try? fileManager.removeItem(at: item)
        }
    }

    @discardableResult
    func ingest(_ content: ClipboardContent) -> ImageHistoryEntry? {
        guard case .image = content else { return nil }

        let destination = destination()
        // This temporary history reference also keeps the security scope open
        // if the user changes destinations while encoding or writing is active.
        destination.accessLease?.retainForHistory()
        do {
            guard let fileURL = try destination.makeSaver().save(content) else {
                destination.accessLease?.releaseFromHistory()
                return nil
            }
            let entry = ImageHistoryEntry(
                fileURL: fileURL,
                isFallback: false,
                accessLease: destination.accessLease
            )
            entries.insert(entry, at: 0)
            return entry
        } catch {
            destination.accessLease?.releaseFromHistory()
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
        } else {
            removed.accessLease?.releaseFromHistory()
        }
    }
}
