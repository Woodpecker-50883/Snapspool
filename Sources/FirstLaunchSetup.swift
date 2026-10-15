import AppKit
import SwiftUI

struct SetupGuideContent: Equatable {
    let title: String
    let introduction: String
    let shortcutInstructions: String
    let destinationInstructions: String
    let manualSettingsPath: String
    let openSettingsButtonTitle: String
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
            doneButtonTitle: L10n.string("setup.done", bundle: bundle, language: language)
        )
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
    let openSettings: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(content.title)
                .font(.title2.bold())
            Text(content.introduction)
            Text(content.shortcutInstructions)
            Text(content.destinationInstructions)
            Text(content.manualSettingsPath)
            HStack {
                Button(content.openSettingsButtonTitle, action: openSettings)
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

    init(
        defaults: UserDefaults = .standard,
        content: SetupGuideContent = .localized(),
        settingsOpener: SystemKeyboardShortcutSettingsOpener = .init()
    ) {
        self.defaults = defaults

        let window = NSWindow()
        window.title = content.title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: FirstLaunchSetupView(
                content: content,
                openSettings: { _ = settingsOpener.open() },
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
        showWindow(nil)
        window?.center()
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}
