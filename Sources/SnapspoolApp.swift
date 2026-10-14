import AppKit
import SwiftUI

@main
@MainActor
struct SnapspoolApp: App {
    private let clipboardMonitor: ClipboardMonitor
    private let menuActions: MenuBarActions
    private let historyStore: HistoryStore
    private let historyPickerController: HistoryPickerController

    init() {
        let historyStore = HistoryStore()
        let pickerController = HistoryPickerController(historyStore: historyStore)
        let clipboardMonitor = ClipboardMonitor { content in
            historyStore.ingest(content)
        }
        self.historyStore = historyStore
        self.clipboardMonitor = clipboardMonitor
        historyPickerController = pickerController
        menuActions = MenuBarActions(
            clipboardMonitor: clipboardMonitor,
            showHistoryPicker: { pickerController.show() }
        )
        clipboardMonitor.start()
    }

    var body: some Scene {
        MenuBarExtra("Snapspool", systemImage: "doc.on.clipboard") {
            MenuBarContent(menu: menuActions.makeMenu())
        }
        .menuBarExtraStyle(.menu)

        Settings {
            EmptyView()
        }
    }
}

@MainActor
private struct MenuBarContent: View {
    let menu: NSMenu

    var body: some View {
        ForEach(Array(menu.items.enumerated()), id: \.offset) { _, item in
            if item.isSeparatorItem {
                Divider()
            } else {
                Button(item.title) {
                    guard let action = item.action else { return }
                    NSApplication.shared.sendAction(action, to: item.target, from: item)
                }
            }
        }
    }
}
