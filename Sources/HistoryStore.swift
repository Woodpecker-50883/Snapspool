import Foundation

struct HistoryEntry: Identifiable, Equatable {
    enum Content: Equatable {
        case image(ImageHistoryEntry)
        case text(Data)
    }

    let id: UUID
    let content: Content
    fileprivate let detectionOrder: UInt64

    init(id: UUID = UUID(), content: Content, detectionOrder: UInt64) {
        self.id = id
        self.content = content
        self.detectionOrder = detectionOrder
    }
}

struct PendingImageHistoryEntry: Equatable {
    fileprivate let id: UUID
    fileprivate let detectionOrder: UInt64
}

@MainActor
final class HistoryStore {
    static let defaultImageLimit = 30
    static let defaultTextLimit = 30
    static let allowedLimitRange = 10...100

    private let imageIngestionService: ImageIngestionService
    private var nextDetectionOrder: UInt64 = 0

    private(set) var entries: [HistoryEntry] = []
    private(set) var imageLimit: Int
    private(set) var textLimit: Int

    init(
        imageLimit: Int = HistoryStore.defaultImageLimit,
        textLimit: Int = HistoryStore.defaultTextLimit,
        imageIngestionService: ImageIngestionService = ImageIngestionService()
    ) {
        self.imageLimit = Self.clampedLimit(imageLimit)
        self.textLimit = Self.clampedLimit(textLimit)
        self.imageIngestionService = imageIngestionService
    }

    var imageCount: Int {
        entries.reduce(into: 0) { count, entry in
            if case .image = entry.content { count += 1 }
        }
    }

    var textCount: Int {
        entries.reduce(into: 0) { count, entry in
            if case .text = entry.content { count += 1 }
        }
    }

    /// Records detection before image conversion or saving starts. Completing a
    /// slow image later therefore cannot move it ahead of newer detections.
    @discardableResult
    func recordDetection(of content: ClipboardContent) -> PendingImageHistoryEntry? {
        let order = claimDetectionOrder()
        switch content {
        case .image:
            return PendingImageHistoryEntry(id: UUID(), detectionOrder: order)
        case let .text(data):
            addText(data, detectionOrder: order)
            return nil
        }
    }

    func completeImageDetection(
        _ pending: PendingImageHistoryEntry,
        with imageEntry: ImageHistoryEntry?
    ) {
        guard let imageEntry else { return }
        entries.append(HistoryEntry(
            id: pending.id,
            content: .image(imageEntry),
            detectionOrder: pending.detectionOrder
        ))
        sortByDetectionOrder()
        _ = trimImagesToLimit()
    }

    @discardableResult
    func ingest(_ content: ClipboardContent) -> Task<Void, Never>? {
        guard let pending = recordDetection(of: content) else { return nil }
        return Task { [imageIngestionService] in
            let imageEntry = await imageIngestionService.ingest(content)
            completeImageDetection(pending, with: imageEntry)
        }
    }

    @discardableResult
    func setImageLimit(_ newValue: Int) -> Task<Void, Never>? {
        imageLimit = Self.clampedLimit(newValue)
        return trimImagesToLimit()
    }

    func setTextLimit(_ newValue: Int) {
        textLimit = Self.clampedLimit(newValue)
        trimTextsToLimit()
    }

    private static func clampedLimit(_ value: Int) -> Int {
        min(max(value, allowedLimitRange.lowerBound), allowedLimitRange.upperBound)
    }

    private func claimDetectionOrder() -> UInt64 {
        defer { nextDetectionOrder &+= 1 }
        return nextDetectionOrder
    }

    private func addText(_ data: Data, detectionOrder: UInt64) {
        if let duplicateIndex = entries.firstIndex(where: { entry in
            if case let .text(existingData) = entry.content {
                return existingData == data
            }
            return false
        }) {
            let duplicate = entries.remove(at: duplicateIndex)
            entries.append(HistoryEntry(
                id: duplicate.id,
                content: duplicate.content,
                detectionOrder: detectionOrder
            ))
        } else {
            entries.append(HistoryEntry(
                content: .text(data),
                detectionOrder: detectionOrder
            ))
        }
        sortByDetectionOrder()
        trimTextsToLimit()
    }

    private func sortByDetectionOrder() {
        entries.sort { $0.detectionOrder > $1.detectionOrder }
    }

    private func trimImagesToLimit() -> Task<Void, Never>? {
        var removedImageEntries: [ImageHistoryEntry] = []
        while imageCount > imageLimit {
            guard let index = entries.lastIndex(where: { entry in
                if case .image = entry.content { return true }
                return false
            }) else { break }
            let removed = entries.remove(at: index)
            if case let .image(imageEntry) = removed.content {
                removedImageEntries.append(imageEntry)
            }
        }
        guard !removedImageEntries.isEmpty else { return nil }
        return Task { [imageIngestionService] in
            for imageEntry in removedImageEntries {
                await imageIngestionService.remove(imageEntry)
            }
        }
    }

    private func trimTextsToLimit() {
        while textCount > textLimit {
            guard let index = entries.lastIndex(where: { entry in
                if case .text = entry.content { return true }
                return false
            }) else { return }
            entries.remove(at: index)
        }
    }
}
