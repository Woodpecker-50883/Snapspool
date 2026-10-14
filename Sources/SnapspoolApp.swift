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
            MenuBarContent(menu: runtime.makeMenu())
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
