import AppKit
import Combine
import SwiftUI

@MainActor
final class HistoryPickerModel: ObservableObject {
    @Published private(set) var entries: [HistoryEntry]
    @Published var selectedID: UUID?

    private(set) var thumbnails: [UUID: NSImage] = [:]
    var onConfirm: (HistoryEntry) -> Void
    var onDismiss: () -> Void

    init(
        entries: [HistoryEntry] = [],
        onConfirm: @escaping (HistoryEntry) -> Void = { _ in },
        onDismiss: @escaping () -> Void = {}
    ) {
        self.entries = entries
        selectedID = entries.first?.id
        self.onConfirm = onConfirm
        self.onDismiss = onDismiss
        rebuildThumbnails()
    }

    func replaceEntries(_ entries: [HistoryEntry]) {
        self.entries = entries
        selectedID = entries.first?.id
        rebuildThumbnails()
    }

    func moveSelection(by offset: Int) {
        guard !entries.isEmpty else { return }
        let currentIndex = selectedID.flatMap { id in
            entries.firstIndex(where: { $0.id == id })
        } ?? 0
        let nextIndex = min(max(currentIndex + offset, 0), entries.count - 1)
        selectedID = entries[nextIndex].id
    }

    func confirmSelection() {
        guard let selectedID,
              let entry = entries.first(where: { $0.id == selectedID }) else { return }
        onConfirm(entry)
        onDismiss()
    }

    func confirm(_ entry: HistoryEntry) {
        selectedID = entry.id
        onConfirm(entry)
        onDismiss()
    }

    func cancel() {
        onDismiss()
    }

    func textPreview(for entry: HistoryEntry) -> String? {
        guard case let .text(data) = entry.content,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let firstLine = String(text.prefix { !$0.isNewline })
        guard firstLine.count > 80 else { return firstLine }
        return String(firstLine.prefix(79)) + "…"
    }

    private func rebuildThumbnails() {
        thumbnails = entries.reduce(into: [:]) { result, entry in
            guard case let .image(imageEntry) = entry.content,
                  let thumbnail = HistoryThumbnail.make(from: imageEntry.fileURL) else { return }
            result[entry.id] = thumbnail
        }
    }
}

enum HistoryThumbnail {
    static let maximumPixelLength = 256

    static func make(from fileURL: URL) -> NSImage? {
        guard let source = NSImage(contentsOf: fileURL),
              let representation = source.representations.first else { return nil }
        let sourceWidth = representation.pixelsWide
        let sourceHeight = representation.pixelsHigh
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        let scale = min(1, CGFloat(maximumPixelLength) / CGFloat(max(sourceWidth, sourceHeight)))
        let width = max(1, Int((CGFloat(sourceWidth) * scale).rounded()))
        let height = max(1, Int((CGFloat(sourceHeight) * scale).rounded()))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let thumbnail = NSImage(size: NSSize(width: width, height: height))
        thumbnail.addRepresentation(bitmap)
        return thumbnail
    }
}

struct HistoryPickerView: View {
    @ObservedObject var model: HistoryPickerModel

    var body: some View {
        Group {
            if model.entries.isEmpty {
                Text("履歴がありません")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(model.entries) { entry in
                                row(for: entry)
                                    .id(entry.id)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: model.selectedID) { _, selectedID in
                        if let selectedID {
                            proxy.scrollTo(selectedID, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: 420, height: 480)
    }

    @ViewBuilder
    private func row(for entry: HistoryEntry) -> some View {
        Button {
            model.confirm(entry)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                switch entry.content {
                case .image:
                    if let thumbnail = model.thumbnails[entry.id] {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 256, maxHeight: 256)
                    } else {
                        Image(systemName: "photo")
                            .frame(width: 48, height: 48)
                    }
                case .text:
                    Text(model.textPreview(for: entry) ?? "")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                entry.id == model.selectedID
                    ? Color.accentColor.opacity(0.22)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

@MainActor
private final class HistoryPickerPanel: NSPanel {
    enum Command {
        case moveUp
        case moveDown
        case confirm
        case cancel
    }

    var handleCommand: ((Command) -> Void)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        let command: Command?
        switch event.keyCode {
        case 126: command = .moveUp
        case 125: command = .moveDown
        case 36, 76: command = .confirm
        case 53: command = .cancel
        default: command = nil
        }
        if let command {
            handleCommand?(command)
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
final class HistoryPickerController: NSObject, NSWindowDelegate {
    private let historyStore: HistoryStore
    private let restorer: ClipboardRestorer
    private let model: HistoryPickerModel
    private let panel: HistoryPickerPanel
    private var isDismissing = false

    init(historyStore: HistoryStore, restorer: ClipboardRestorer = ClipboardRestorer()) {
        self.historyStore = historyStore
        self.restorer = restorer
        model = HistoryPickerModel()
        panel = HistoryPickerPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.transient, .moveToActiveSpace]
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: HistoryPickerView(model: model))
        panel.handleCommand = { [weak model] command in
            switch command {
            case .moveUp: model?.moveSelection(by: -1)
            case .moveDown: model?.moveSelection(by: 1)
            case .confirm: model?.confirmSelection()
            case .cancel: model?.cancel()
            }
        }
        model.onConfirm = { [weak restorer] entry in
            try? restorer?.restore(entry)
        }
        model.onDismiss = { [weak self] in
            self?.dismiss()
        }
    }

    func show() {
        model.replaceEntries(historyStore.entries)
        panel.center()
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func dismiss() {
        guard panel.isVisible, !isDismissing else { return }
        isDismissing = true
        panel.close()
        isDismissing = false
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }
}
