import AppKit
import SwiftUI

struct SetupGuideContent: Equatable {
    let title: String
    let introduction: String
    let shortcutInstructions: String
    let destinationInstructions: String
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
            doneButtonTitle: L10n.string("setup.done", bundle: bundle, language: language)
        )
    }
}

private struct FirstLaunchSetupView: View {
    let content: SetupGuideContent
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(content.title)
                .font(.title2.bold())
            Text(content.introduction)
            Text(content.shortcutInstructions)
            Text(content.destinationInstructions)
            HStack {
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

    init(defaults: UserDefaults = .standard, content: SetupGuideContent = .localized()) {
        self.defaults = defaults

        let window = NSWindow()
        window.title = content.title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: FirstLaunchSetupView(content: content) { [weak window] in
                window?.close()
            }
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
