import AppKit
import Foundation

struct PasteboardRepresentation: Equatable {
    let type: NSPasteboard.PasteboardType
    let data: Data
}

@MainActor
protocol ClipboardPasteboardWriting {
    @discardableResult
    func replaceContents(with representations: [PasteboardRepresentation]) -> Bool
}

@MainActor
struct SystemClipboardPasteboardWriter: ClipboardPasteboardWriting {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func replaceContents(with representations: [PasteboardRepresentation]) -> Bool {
        let item = Self.makeItem(with: representations)

        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    static func makeItem(with representations: [PasteboardRepresentation]) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        for representation in representations {
            item.setData(representation.data, forType: representation.type)
        }
        return item
    }
}

enum ClipboardRestorationError: Error {
    case invalidSavedImage
    case tiffEncodingFailed
    case pasteboardWriteFailed
}

@MainActor
final class ClipboardRestorer {
    private let pasteboard: any ClipboardPasteboardWriting

    init(pasteboard: any ClipboardPasteboardWriting = SystemClipboardPasteboardWriter()) {
        self.pasteboard = pasteboard
    }

    func restore(_ entry: HistoryEntry) throws {
        let representations: [PasteboardRepresentation]

        switch entry.content {
        case let .image(imageEntry):
            let pngData = try imageEntry.restorationPNGData()
            guard let bitmap = NSBitmapImageRep(data: pngData) else {
                throw ClipboardRestorationError.invalidSavedImage
            }
            guard let tiffData = bitmap.representation(using: .tiff, properties: [:]) else {
                throw ClipboardRestorationError.tiffEncodingFailed
            }
            representations = [
                PasteboardRepresentation(type: ClipboardContentSelector.pngType, data: pngData),
                PasteboardRepresentation(type: ClipboardContentSelector.tiffType, data: tiffData),
                PasteboardRepresentation(type: ClipboardContentSelector.restoredType, data: Data()),
            ]

        case let .text(data):
            representations = [
                PasteboardRepresentation(type: ClipboardContentSelector.plainTextType, data: data),
                PasteboardRepresentation(type: ClipboardContentSelector.restoredType, data: Data()),
            ]
        }

        guard pasteboard.replaceContents(with: representations) else {
            throw ClipboardRestorationError.pasteboardWriteFailed
        }
    }
}
