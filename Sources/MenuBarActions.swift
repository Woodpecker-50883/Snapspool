import AppKit

@MainActor
final class MenuBarActions: NSObject {
    private let clipboardMonitor: ClipboardMonitor
    private let showHistoryPicker: () -> Void
    private let terminateApplication: () -> Void

    init(
        clipboardMonitor: ClipboardMonitor = ClipboardMonitor { _ in },
        showHistoryPicker: @escaping () -> Void = {},
        terminateApplication: @escaping () -> Void = { NSApplication.shared.terminate(nil) }
    ) {
        self.clipboardMonitor = clipboardMonitor
        self.showHistoryPicker = showHistoryPicker
        self.terminateApplication = terminateApplication
    }

    var isMonitoringPaused: Bool {
        clipboardMonitor.isPaused
    }

    var monitoringMenuTitle: String {
        isMonitoringPaused ? "監視を再開" : "監視の一時停止"
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(makeItem(title: "履歴", action: #selector(openHistory(_:))))
        menu.addItem(makeItem(title: monitoringMenuTitle, action: #selector(pauseMonitoring(_:))))
        menu.addItem(makeItem(title: "設定", action: #selector(openSettings(_:))))
        menu.addItem(.separator())
        menu.addItem(makeItem(title: "終了", action: #selector(quit(_:))))
        return menu
    }

    @objc func openHistory(_ sender: Any? = nil) {
        showHistoryPicker()
    }

    @objc func pauseMonitoring(_ sender: NSMenuItem? = nil) {
        clipboardMonitor.togglePaused()
        sender?.title = monitoringMenuTitle
    }

    @objc func openSettings(_ sender: Any? = nil) {
        // Implemented with the settings screen in a later task.
    }

    @objc func quit(_ sender: Any? = nil) {
        terminateApplication()
    }

    private func makeItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
}
