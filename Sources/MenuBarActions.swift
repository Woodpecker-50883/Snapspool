import AppKit

/// The app target's narrow entry point into the shared implementation module.
/// Keeping assembly here ensures the app and tests both use the single compiled
/// copy of the implementation provided by the static library target.
@MainActor
public final class SnapspoolRuntime {
    private let clipboardMonitor: ClipboardMonitor
    private let menuActions: MenuBarActions
    private let historyStore: HistoryStore
    private let historyPickerController: HistoryPickerController
    private let globalHotKeyController: GlobalHotKeyController
    public let settings: AppSettings
    public let monitoringState: MonitoringState

    public init() {
        let settings = AppSettings()
        let imageDestination = MutableImageDestination(url: settings.destinationURL)
        let imageService = ImageIngestionService(
            destinationProvider: { imageDestination.snapshot() }
        )
        let historyStore = HistoryStore(
            imageLimit: settings.imageLimit,
            textLimit: settings.textLimit,
            imageIngestionService: imageService
        )
        let pickerController = HistoryPickerController(historyStore: historyStore)
        let monitoringState = MonitoringState()
        let clipboardMonitor = ClipboardMonitor(monitoringState: monitoringState) { content in
            historyStore.ingest(content)
        }

        self.historyStore = historyStore
        self.settings = settings
        self.monitoringState = monitoringState
        self.clipboardMonitor = clipboardMonitor
        historyPickerController = pickerController
        globalHotKeyController = GlobalHotKeyController(
            configuredShortcut: settings.shortcut,
            showHistoryPicker: { pickerController.show() }
        )
        settings.connect(
            historyStore: historyStore,
            hotKeyController: globalHotKeyController,
            imageDestination: imageDestination
        )
        menuActions = MenuBarActions(
            clipboardMonitor: clipboardMonitor,
            showHistoryPicker: { pickerController.show() },
            hasHotKeyRegistrationWarning: { [globalHotKeyController] in
                globalHotKeyController.hasRegistrationWarning
            }
        )
    }

    public func start() {
        clipboardMonitor.start()
        globalHotKeyController.start()
    }

    public func makeMenu() -> NSMenu {
        menuActions.makeMenu()
    }
}

@MainActor
final class MenuBarActions: NSObject {
    private let clipboardMonitor: ClipboardMonitor
    private let showHistoryPicker: () -> Void
    private let terminateApplication: () -> Void
    private let hasHotKeyRegistrationWarning: () -> Bool
    private let showSettings: () -> Void
    private let localize: (String) -> String

    init(
        clipboardMonitor: ClipboardMonitor = ClipboardMonitor { _ in },
        showHistoryPicker: @escaping () -> Void = {},
        hasHotKeyRegistrationWarning: @escaping () -> Bool = { false },
        showSettings: @escaping () -> Void = {
            NSApplication.shared.sendAction(
                Selector(("showSettingsWindow:")),
                to: nil,
                from: nil
            )
        },
        localize: @escaping (String) -> String = { L10n.string($0) },
        terminateApplication: @escaping () -> Void = { NSApplication.shared.terminate(nil) }
    ) {
        self.clipboardMonitor = clipboardMonitor
        self.showHistoryPicker = showHistoryPicker
        self.hasHotKeyRegistrationWarning = hasHotKeyRegistrationWarning
        self.showSettings = showSettings
        self.localize = localize
        self.terminateApplication = terminateApplication
    }

    var isMonitoringPaused: Bool {
        clipboardMonitor.isPaused
    }

    var monitoringMenuTitle: String {
        localize(isMonitoringPaused ? "menu.resume-monitoring" : "menu.pause-monitoring")
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(makeItem(title: localize("menu.history"), action: #selector(openHistory(_:))))
        if hasHotKeyRegistrationWarning() {
            let warning = NSMenuItem(
                title: localize("menu.shortcut-warning"),
                action: nil,
                keyEquivalent: ""
            )
            warning.isEnabled = false
            menu.addItem(warning)
        }
        menu.addItem(makeItem(title: monitoringMenuTitle, action: #selector(pauseMonitoring(_:))))
        menu.addItem(makeItem(title: localize("menu.settings"), action: #selector(openSettings(_:))))
        menu.addItem(.separator())
        menu.addItem(makeItem(title: localize("menu.quit"), action: #selector(quit(_:))))
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
        showSettings()
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
