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
    private let firstLaunchSetupController: FirstLaunchSetupController
    private let presentStatusMenu: @MainActor (NSMenu) -> Void
    private let presentFirstLaunchSetupOnStart: @MainActor () -> Void
    private let ownedStatusItemController: MenuBarStatusItemController?
    var statusItemController: MenuBarStatusItemController {
        guard let ownedStatusItemController else {
            preconditionFailure("SnapspoolRuntime was created without a status item")
        }
        return ownedStatusItemController
    }
    public let settings: AppSettings
    public let monitoringState: MonitoringState

    public convenience init() {
        self.init(imageSaveNotifier: UserNotificationImageSaveNotifier())
    }

    init(
        imageSaveNotifier: any ImageSaveNotifying,
        settings: AppSettings = AppSettings(),
        hotKeyRegistrar: any GlobalHotKeyRegistering = CarbonGlobalHotKeyRegistrar(),
        clipboardPasteboard: any ClipboardPasteboardReading = SystemClipboardPasteboard(),
        showHistoryPicker: (@MainActor @Sendable () -> Void)? = nil,
        presentStatusMenu: (@MainActor (NSMenu) -> Void)? = nil,
        presentFirstLaunchSetupOnStart: (@MainActor () -> Void)? = nil,
        createStatusItem: Bool = true
    ) {
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
        let pickerController = HistoryPickerController(historyStore: historyStore, settings: settings)
        let settingsWindowController = SettingsWindowController(settings: settings)
        let monitoringState = MonitoringState()
        let clipboardMonitor = ClipboardMonitor(
            pasteboard: clipboardPasteboard,
            monitoringState: monitoringState
        ) { content in
            historyStore.ingest(content)
        }
        let openHistoryPicker = showHistoryPicker ?? { pickerController.show() }

        self.historyStore = historyStore
        self.settings = settings
        self.monitoringState = monitoringState
        self.clipboardMonitor = clipboardMonitor
        historyPickerController = pickerController
        self.settingsWindowController = settingsWindowController
        let firstLaunchSetupController = FirstLaunchSetupController()
        self.firstLaunchSetupController = firstLaunchSetupController
        self.presentFirstLaunchSetupOnStart = presentFirstLaunchSetupOnStart ?? {
            _ = firstLaunchSetupController.showIfNeeded()
        }
        globalHotKeyController = GlobalHotKeyController(
            registrar: hotKeyRegistrar,
            configuredShortcut: settings.shortcut,
            showHistoryPicker: openHistoryPicker
        )
        settings.connect(
            historyStore: historyStore,
            hotKeyController: globalHotKeyController,
            imageDestination: imageDestination
        )
        let menuActions = MenuBarActions(
            clipboardMonitor: clipboardMonitor,
            showHistoryPicker: openHistoryPicker,
            hasHotKeyRegistrationWarning: { [globalHotKeyController] in
                globalHotKeyController.hasRegistrationWarning
            },
            showSettings: { settingsWindowController.show() },
            showSetupGuide: { firstLaunchSetupController.show() }
        )
        self.menuActions = menuActions
        let statusItemController = createStatusItem
            ? MenuBarStatusItemController(menu: menuActions.makeMenu())
            : nil
        ownedStatusItemController = statusItemController
        self.presentStatusMenu = presentStatusMenu ?? { [weak statusItemController] menu in
            statusItemController?.updateMenu(menu)
        }
    }

    public func start() {
        startCoreServices()
        presentFirstLaunchSetupOnStart()
    }

    func startCoreServices() {
        clipboardMonitor.start()
        globalHotKeyController.start()
        presentStatusMenu(menuActions.makeMenu())
    }

    func stop() {
        clipboardMonitor.stop()
        globalHotKeyController.stop()
    }

    @discardableResult
    func presentFirstLaunchSetupIfNeeded() -> Bool {
        firstLaunchSetupController.showIfNeeded()
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

    public convenience init(menu: NSMenu) {
        self.init(menu: menu) {
            Self.loadMenuBarImage()
        }
    }

    init(menu: NSMenu, loadImage: () -> NSImage?) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            Self.configure(button: button, image: loadImage())
        }
        statusItem.menu = menu
    }

    func updateMenu(_ menu: NSMenu) {
        statusItem.menu = menu
    }

    static func loadMenuBarImage(
        from bundle: Bundle = .main
    ) -> NSImage? {
        guard let image = bundle.image(forResource: NSImage.Name("MenuBarIcon")) else {
            return nil
        }
        image.isTemplate = true
        image.accessibilityDescription = "Snapspool"
        return image
    }

    static func configure(button: NSButton, image: NSImage?) {
        if let image {
            button.image = image
        } else {
            // Keep the status item visible and usable even if the asset is
            // missing or cannot be decoded in a damaged installation.
            button.title = "Snapspool"
        }
        button.toolTip = "Snapspool"
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
    private let showSetupGuide: () -> Void
    private let privacyPolicyURL: URL?
    private let openURL: (URL) -> Void
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
        showSetupGuide: @escaping () -> Void = {},
        privacyPolicyURL: URL? = AppLinks.privacyPolicyURL,
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        localize: @escaping (String) -> String = { L10n.string($0) },
        terminateApplication: @escaping () -> Void = { NSApplication.shared.terminate(nil) }
    ) {
        self.clipboardMonitor = clipboardMonitor
        self.showHistoryPicker = showHistoryPicker
        self.hasHotKeyRegistrationWarning = hasHotKeyRegistrationWarning
        self.showSettings = showSettings
        self.showSetupGuide = showSetupGuide
        self.privacyPolicyURL = privacyPolicyURL
        self.openURL = openURL
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
        menu.addItem(makeItem(title: localize("menu.setup-guide"), action: #selector(openSetupGuide(_:))))
        if privacyPolicyURL != nil {
            menu.addItem(makeItem(
                title: localize("menu.privacy-policy"),
                action: #selector(openPrivacyPolicy(_:))
            ))
        }
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

    @objc func openSetupGuide(_ sender: Any? = nil) {
        showSetupGuide()
    }

    @objc func openPrivacyPolicy(_ sender: Any? = nil) {
        guard let privacyPolicyURL else { return }
        openURL(privacyPolicyURL)
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
