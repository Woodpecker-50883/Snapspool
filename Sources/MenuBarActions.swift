import AppKit

enum MenuBarItem: String, CaseIterable {
    case pauseMonitoring = "監視の一時停止"
    case settings = "設定"
    case quit = "終了"
}

@MainActor
final class MenuBarActions {
    private let clipboardMonitor: ClipboardMonitor
    private let terminateApplication: () -> Void

    init(
        clipboardMonitor: ClipboardMonitor = ClipboardMonitor { _ in },
        terminateApplication: @escaping () -> Void = { NSApplication.shared.terminate(nil) }
    ) {
        self.clipboardMonitor = clipboardMonitor
        self.terminateApplication = terminateApplication
    }

    var isMonitoringPaused: Bool {
        clipboardMonitor.isPaused
    }

    var monitoringMenuTitle: String {
        isMonitoringPaused
            ? "監視を再開"
            : MenuBarItem.pauseMonitoring.rawValue
    }

    func pauseMonitoring() {
        clipboardMonitor.togglePaused()
    }

    func openSettings() {
        // Implemented with the settings screen in a later task.
    }

    func quit() {
        terminateApplication()
    }
}
