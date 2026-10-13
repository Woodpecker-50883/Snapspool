import AppKit

enum MenuBarItem: String, CaseIterable {
    case pauseMonitoring = "監視の一時停止"
    case settings = "設定"
    case quit = "終了"
}

@MainActor
final class MenuBarActions {
    private let terminateApplication: () -> Void

    init(terminateApplication: @escaping () -> Void = {
        NSApplication.shared.terminate(nil)
    }) {
        self.terminateApplication = terminateApplication
    }

    func pauseMonitoring() {
        // Implemented with the clipboard monitor in a later task.
    }

    func openSettings() {
        // Implemented with the settings screen in a later task.
    }

    func quit() {
        terminateApplication()
    }
}
