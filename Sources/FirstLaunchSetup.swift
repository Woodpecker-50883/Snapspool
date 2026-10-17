import AppKit
import Combine
import SwiftUI

struct SetupGuideContent: Equatable {
    let title: String
    let introduction: String
    let shortcutInstructions: String
    let destinationInstructions: String
    let autoPasteInstructions: String
    let emptyHistoryRestartNote: String
    let manualSettingsPath: String
    let openSettingsButtonTitle: String
    let enableAutoPasteButtonTitle: String
    let restartAutoPasteButtonTitle: String
    let permissionUnauthorizedStatus: String
    let permissionRestartRequiredStatus: String
    let permissionActiveStatus: String
    let doneButtonTitle: String

    static func localized(
        bundle: Bundle = .main,
        language: String? = nil
    ) -> SetupGuideContent {
        SetupGuideContent(
            title: L10n.string("setup.title", bundle: bundle, language: language),
            introduction: L10n.string("setup.introduction", bundle: bundle, language: language),
            shortcutInstructions: L10n.string(
                "setup.shortcut-instructions",
                bundle: bundle,
                language: language
            ),
            destinationInstructions: L10n.string(
                "setup.destination-instructions",
                bundle: bundle,
                language: language
            ),
            autoPasteInstructions: L10n.string(
                "setup.auto-paste-instructions",
                bundle: bundle,
                language: language
            ),
            emptyHistoryRestartNote: L10n.string(
                "setup.empty-history-restart-note",
                bundle: bundle,
                language: language
            ),
            manualSettingsPath: L10n.string(
                "setup.manual-settings-path",
                bundle: bundle,
                language: language
            ),
            openSettingsButtonTitle: L10n.string(
                "setup.open-settings",
                bundle: bundle,
                language: language
            ),
            enableAutoPasteButtonTitle: L10n.string(
                "setup.enable-auto-paste",
                bundle: bundle,
                language: language
            ),
            restartAutoPasteButtonTitle: L10n.string(
                "autopaste.restart",
                bundle: bundle,
                language: language
            ),
            permissionUnauthorizedStatus: L10n.string(
                "setup.permission-status-unauthorized",
                bundle: bundle,
                language: language
            ),
            permissionRestartRequiredStatus: L10n.string(
                "setup.permission-status-restart-required",
                bundle: bundle,
                language: language
            ),
            permissionActiveStatus: L10n.string(
                "setup.permission-status-active",
                bundle: bundle,
                language: language
            ),
            doneButtonTitle: L10n.string("setup.done", bundle: bundle, language: language)
        )
    }
}

@MainActor
final class FirstLaunchSetupModel: ObservableObject {
    @Published var permissionState: AutoPastePermissionState

    init(permissionState: AutoPastePermissionState) {
        self.permissionState = permissionState
    }
}

struct SystemKeyboardShortcutSettingsOpener {
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts"
    )!

    private let openURL: (URL) -> Bool

    init(openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.openURL = openURL
    }

    @discardableResult
    func open() -> Bool {
        openURL(Self.settingsURL)
    }
}

struct FirstLaunchSetupView: View {
    let content: SetupGuideContent
    @ObservedObject var model: FirstLaunchSetupModel
    let openSettings: () -> Void
    let enableAutoPaste: () -> Void
    let restartAutoPaste: () -> Void
    let dismiss: () -> Void

    var permissionStatusText: String {
        switch model.permissionState {
        case .unauthorized: content.permissionUnauthorizedStatus
        case .restartRequired: content.permissionRestartRequiredStatus
        case .active: content.permissionActiveStatus
        }
    }

    var showsRestartButton: Bool {
        model.permissionState == .restartRequired
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(content.title)
                .font(.title2.bold())
            Text(content.introduction)
            Text(content.shortcutInstructions)
            Text(content.destinationInstructions)
            Divider()
            Text(content.autoPasteInstructions)
            Text(permissionStatusText)
                .fontWeight(.semibold)
            Text(content.emptyHistoryRestartNote)
            Text(content.manualSettingsPath)
            HStack {
                Button(content.openSettingsButtonTitle, action: openSettings)
                Button(content.enableAutoPasteButtonTitle, action: enableAutoPaste)
                if showsRestartButton {
                    Button(content.restartAutoPasteButtonTitle, action: restartAutoPaste)
                }
                Spacer()
                Button(content.doneButtonTitle, action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .frame(width: 520)
    }
}

@MainActor
final class FirstLaunchSetupController: NSWindowController, NSWindowDelegate {
    private static let didPresentKey = "setup.didPresentFirstLaunchGuide"

    private let defaults: UserDefaults
    private let autoPastePermissionGuide: any AutoPastePermissionGuiding
    private let model: FirstLaunchSetupModel

    init(
        defaults: UserDefaults = .standard,
        content: SetupGuideContent = .localized(),
        settingsOpener: SystemKeyboardShortcutSettingsOpener = .init(),
        autoPastePermissionGuide: any AutoPastePermissionGuiding = SystemAutoPasteNotifier()
    ) {
        self.defaults = defaults
        self.autoPastePermissionGuide = autoPastePermissionGuide
        let model = FirstLaunchSetupModel(permissionState: autoPastePermissionGuide.permissionState)
        self.model = model
        autoPastePermissionGuide.setPermissionStateHandler { [weak model] state in
            model?.permissionState = state
        }

        let window = NSWindow()
        window.title = content.title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: FirstLaunchSetupView(
                content: content,
                model: model,
                openSettings: { _ = settingsOpener.open() },
                enableAutoPaste: { autoPastePermissionGuide.requestPermissionFromSetup() },
                restartAutoPaste: { autoPastePermissionGuide.restartFromSetup() },
                dismiss: { [weak window] in window?.close() }
            )
        )
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @discardableResult
    func showIfNeeded() -> Bool {
        guard !defaults.bool(forKey: Self.didPresentKey) else { return false }

        defaults.set(true, forKey: Self.didPresentKey)
        show()
        return true
    }

    func show() {
        autoPastePermissionGuide.setSetupGuideVisible(true)
        showWindow(nil)
        window?.center()
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        autoPastePermissionGuide.setSetupGuideVisible(false)
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}
