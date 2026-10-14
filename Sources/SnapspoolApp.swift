import AppKit
import Snapspool
import SwiftUI

@main
@MainActor
struct SnapspoolApp: App {
    private let runtime: SnapspoolRuntime

    init() {
        runtime = SnapspoolRuntime()
        runtime.start()
    }

    var body: some Scene {
        MenuBarExtra("Snapspool", systemImage: "doc.on.clipboard") {
            MenuBarContent(runtime: runtime)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            AppSettingsView(settings: runtime.settings)
        }
    }
}

@MainActor
private struct MenuBarContent: View {
    let runtime: SnapspoolRuntime
    @ObservedObject private var monitoringState: MonitoringState

    init(runtime: SnapspoolRuntime) {
        self.runtime = runtime
        monitoringState = runtime.monitoringState
    }

    var body: some View {
        let menu = runtime.makeMenu()
        ForEach(Array(menu.items.enumerated()), id: \.offset) { _, item in
            if item.isSeparatorItem {
                Divider()
            } else {
                Button(item.title) {
                    guard let action = item.action else { return }
                    NSApplication.shared.sendAction(action, to: item.target, from: item)
                }
                .disabled(!item.isEnabled)
            }
        }
    }
}
