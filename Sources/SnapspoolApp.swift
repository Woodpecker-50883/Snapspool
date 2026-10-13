import AppKit
import SwiftUI

@main
@MainActor
struct SnapspoolApp: App {
    private let clipboardMonitor: ClipboardMonitor
    private let menuActions: MenuBarActions

    init() {
        let imageFolderSaver = ImageFolderSaver()
        let clipboardMonitor = ClipboardMonitor { content in
            // Failure recovery and user notification are added in the next phase.
            _ = try? imageFolderSaver.save(content)
        }
        self.clipboardMonitor = clipboardMonitor
        menuActions = MenuBarActions(clipboardMonitor: clipboardMonitor)
        clipboardMonitor.start()
    }

    var body: some Scene {
        MenuBarExtra("Snapspool", systemImage: "doc.on.clipboard") {
            Button(menuActions.monitoringMenuTitle) {
                menuActions.pauseMonitoring()
            }
            Button(MenuBarItem.settings.rawValue) {
                menuActions.openSettings()
            }
            Divider()
            Button(MenuBarItem.quit.rawValue) {
                menuActions.quit()
            }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            EmptyView()
        }
    }
}
