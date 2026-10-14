import AppKit
import Snapspool
import SwiftUI

@main
struct SnapspoolApp: App {
    @NSApplicationDelegateAdaptor(SnapspoolAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
private final class SnapspoolAppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: SnapspoolRuntime?
    private var statusItemController: MenuBarStatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let runtime = SnapspoolRuntime()
        runtime.start()

        self.runtime = runtime
        statusItemController = MenuBarStatusItemController(menu: runtime.makeMenu())
    }
}
