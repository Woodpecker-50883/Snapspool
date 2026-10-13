import AppKit
import SwiftUI

@main
@MainActor
struct SnapspoolApp: App {
    private let menuActions = MenuBarActions()

    var body: some Scene {
        MenuBarExtra("Snapspool", systemImage: "doc.on.clipboard") {
            Button(MenuBarItem.pauseMonitoring.rawValue) {
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
