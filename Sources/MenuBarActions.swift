import AppKit
import SwiftUI

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
    private let settingsWindowController: SettingsWindowController
    let statusItemController: MenuBarStatusItemController
    public let settings: AppSettings
    public let monitoringState: MonitoringState

    public convenience init() {
        self.init(imageSaveNotifier: UserNotificationImageSaveNotifier())
    }

    init(imageSaveNotifier: any ImageSaveNotifying) {
        let settings = AppSettings()
        let imageDestination = MutableImageDestination(url: settings.destinationURL)
        let imageService = ImageIngestionService(
            destinationProvider: { imageDestination.snapshot() },
            notifier: imageSaveNotifier
        )
        let historyStore = HistoryStore(
            imageLimit: settings.imageLimit,
            textLimit: settings.textLimit,
            imageIngestionService: imageService
        )
        let pickerController = HistoryPickerController(historyStore: historyStore)
        let settingsWindowController = SettingsWindowController(settings: settings)
        let monitoringState = MonitoringState()
        let clipboardMonitor = ClipboardMonitor(monitoringState: monitoringState) { content in
            historyStore.ingest(content)
        }

        self.historyStore = historyStore
        self.settings = settings
        self.monitoringState = monitoringState
        self.clipboardMonitor = clipboardMonitor
        historyPickerController = pickerController
        self.settingsWindowController = settingsWindowController
        globalHotKeyController = GlobalHotKeyController(
            configuredShortcut: settings.shortcut,
            showHistoryPicker: { pickerController.show() }
        )
        settings.connect(
            historyStore: historyStore,
            hotKeyController: globalHotKeyController,
            imageDestination: imageDestination
        )
        let menuActions = MenuBarActions(
            clipboardMonitor: clipboardMonitor,
            showHistoryPicker: { pickerController.show() },
            hasHotKeyRegistrationWarning: { [globalHotKeyController] in
                globalHotKeyController.hasRegistrationWarning
            },
            showSettings: { settingsWindowController.show() }
        )
        self.menuActions = menuActions
        statusItemController = MenuBarStatusItemController(menu: menuActions.makeMenu())
    }

    public func start() {
        clipboardMonitor.start()
        globalHotKeyController.start()
    }

    public func makeMenu() -> NSMenu {
        menuActions.makeMenu()
    }
}

/// Owns the AppKit status item for the lifetime of the application. Using an
/// explicit `NSStatusItem` makes creation independent of SwiftUI scene timing.
@MainActor
public final class MenuBarStatusItemController {
    let statusItem: NSStatusItem

    public init(menu: NSMenu) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "doc.on.clipboard",
                accessibilityDescription: "Snapspool"
            )
            button.image?.isTemplate = true
            button.toolTip = "Snapspool"
        }
        statusItem.menu = menu
    }

    deinit {
        MainActor.assumeIsolated {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }
}

@MainActor
private final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    init(settings: AppSettings) {
        let window = NSWindow(contentViewController: NSHostingController(
            rootView: AppSettingsView(settings: settings)
        ))
        window.title = L10n.string("menu.settings")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        showWindow(nil)
        window?.center()
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
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
