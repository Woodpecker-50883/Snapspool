import AppKit
import Carbon.HIToolbox
import Combine
import Foundation
import SwiftUI

final class MutableImageDestination: @unchecked Sendable {
    private let lock = NSLock()
    private var storedURL: URL

    init(url: URL) {
        storedURL = url
    }

    var url: URL {
        lock.withLock { storedURL }
    }

    func update(to url: URL) {
        lock.withLock { storedURL = url }
    }

    func makeSaver() -> ImageFolderSaver {
        ImageFolderSaver(destinationDirectory: url)
    }
}

@MainActor
public final class AppSettings: ObservableObject {
    private enum Key {
        static let destinationPath = "settings.destinationPath"
        static let imageLimit = "settings.imageLimit"
        static let textLimit = "settings.textLimit"
        static let shortcutKeyCode = "settings.shortcut.keyCode"
        static let shortcutModifiers = "settings.shortcut.modifiers"
    }

    @Published public private(set) var destinationURL: URL
    @Published public private(set) var imageLimit: Int
    @Published public private(set) var textLimit: Int
    @Published private(set) var shortcut: GlobalShortcut
    @Published public var shortcutErrorMessage: String?

    private let defaults: UserDefaults
    private var historyStore: HistoryStore?
    private var hotKeyController: GlobalHotKeyController?
    private var imageDestination: MutableImageDestination?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let path = defaults.string(forKey: Key.destinationPath), !path.isEmpty {
            destinationURL = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            destinationURL = ImageFolderSaver.defaultDestinationDirectory()
        }
        let storedImageLimit = defaults.object(forKey: Key.imageLimit) as? Int
            ?? HistoryStore.defaultImageLimit
        let storedTextLimit = defaults.object(forKey: Key.textLimit) as? Int
            ?? HistoryStore.defaultTextLimit
        imageLimit = Self.clampedLimit(storedImageLimit)
        textLimit = Self.clampedLimit(storedTextLimit)

        if defaults.object(forKey: Key.shortcutKeyCode) != nil,
           defaults.object(forKey: Key.shortcutModifiers) != nil {
            shortcut = GlobalShortcut(
                keyCode: UInt32(defaults.integer(forKey: Key.shortcutKeyCode)),
                modifiers: UInt32(defaults.integer(forKey: Key.shortcutModifiers))
            )
        } else {
            shortcut = .defaultShortcut
        }
    }

    func connect(
        historyStore: HistoryStore,
        hotKeyController: GlobalHotKeyController,
        imageDestination: MutableImageDestination
    ) {
        self.historyStore = historyStore
        self.hotKeyController = hotKeyController
        self.imageDestination = imageDestination
    }

    public func setImageLimit(_ value: Int) {
        let value = Self.clampedLimit(value)
        imageLimit = value
        defaults.set(value, forKey: Key.imageLimit)
        _ = historyStore?.setImageLimit(value)
    }

    public func setTextLimit(_ value: Int) {
        let value = Self.clampedLimit(value)
        textLimit = value
        defaults.set(value, forKey: Key.textLimit)
        historyStore?.setTextLimit(value)
    }

    public func setDestinationURL(_ url: URL) {
        destinationURL = url
        defaults.set(url.path, forKey: Key.destinationPath)
        imageDestination?.update(to: url)
    }

    @discardableResult
    func setShortcut(_ candidate: GlobalShortcut) -> Bool {
        guard let hotKeyController else { return false }
        guard hotKeyController.updateShortcut(candidate) else {
            shortcutErrorMessage = "このショートカットは登録できません。以前の設定を使用します。"
            return false
        }
        shortcut = candidate
        shortcutErrorMessage = nil
        defaults.set(Int(candidate.keyCode), forKey: Key.shortcutKeyCode)
        defaults.set(Int(candidate.modifiers), forKey: Key.shortcutModifiers)
        return true
    }

    private static func clampedLimit(_ value: Int) -> Int {
        min(max(value, HistoryStore.allowedLimitRange.lowerBound),
            HistoryStore.allowedLimitRange.upperBound)
    }
}

public struct AppSettingsView: View {
    private struct ShortcutChoice: Identifiable {
        let title: String
        let value: UInt32
        var id: UInt32 { value }
    }

    @ObservedObject private var settings: AppSettings

    private static let shortcutKeys: [ShortcutChoice] = [
        .init(title: "A", value: UInt32(kVK_ANSI_A)), .init(title: "B", value: UInt32(kVK_ANSI_B)),
        .init(title: "C", value: UInt32(kVK_ANSI_C)), .init(title: "D", value: UInt32(kVK_ANSI_D)),
        .init(title: "E", value: UInt32(kVK_ANSI_E)), .init(title: "F", value: UInt32(kVK_ANSI_F)),
        .init(title: "G", value: UInt32(kVK_ANSI_G)), .init(title: "H", value: UInt32(kVK_ANSI_H)),
        .init(title: "I", value: UInt32(kVK_ANSI_I)), .init(title: "J", value: UInt32(kVK_ANSI_J)),
        .init(title: "K", value: UInt32(kVK_ANSI_K)), .init(title: "L", value: UInt32(kVK_ANSI_L)),
        .init(title: "M", value: UInt32(kVK_ANSI_M)), .init(title: "N", value: UInt32(kVK_ANSI_N)),
        .init(title: "O", value: UInt32(kVK_ANSI_O)), .init(title: "P", value: UInt32(kVK_ANSI_P)),
        .init(title: "Q", value: UInt32(kVK_ANSI_Q)), .init(title: "R", value: UInt32(kVK_ANSI_R)),
        .init(title: "S", value: UInt32(kVK_ANSI_S)), .init(title: "T", value: UInt32(kVK_ANSI_T)),
        .init(title: "U", value: UInt32(kVK_ANSI_U)), .init(title: "V", value: UInt32(kVK_ANSI_V)),
        .init(title: "W", value: UInt32(kVK_ANSI_W)), .init(title: "X", value: UInt32(kVK_ANSI_X)),
        .init(title: "Y", value: UInt32(kVK_ANSI_Y)), .init(title: "Z", value: UInt32(kVK_ANSI_Z))
    ]
    private static let modifierChoices: [ShortcutChoice] = [
        .init(title: "⌘⇧", value: UInt32(cmdKey | shiftKey)),
        .init(title: "⌘⌥", value: UInt32(cmdKey | optionKey)),
        .init(title: "⌃⇧", value: UInt32(controlKey | shiftKey)),
        .init(title: "⌃⌥", value: UInt32(controlKey | optionKey))
    ]

    public init(settings: AppSettings) {
        self.settings = settings
    }

    public var body: some View {
        Form {
            LabeledContent("保存先フォルダ") {
                HStack {
                    Text(settings.destinationURL.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("選択…", action: chooseDestination)
                }
            }
            Stepper(value: imageLimitBinding, in: 10...100) {
                Text("画像の履歴件数: \(settings.imageLimit)")
            }
            Stepper(value: textLimitBinding, in: 10...100) {
                Text("テキストの履歴件数: \(settings.textLimit)")
            }
            LabeledContent("ショートカット") {
                HStack {
                    Picker("修飾キー", selection: shortcutModifiersBinding) {
                        ForEach(Self.modifierChoices) { choice in
                            Text(choice.title).tag(choice.value)
                        }
                    }
                    .labelsHidden()
                    Picker("キー", selection: shortcutKeyBinding) {
                        ForEach(Self.shortcutKeys) { choice in
                            Text(choice.title).tag(choice.value)
                        }
                    }
                    .labelsHidden()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 260)
        .alert(
            "ショートカットを変更できません",
            isPresented: Binding(
                get: { settings.shortcutErrorMessage != nil },
                set: { if !$0 { settings.shortcutErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(settings.shortcutErrorMessage ?? "")
        }
    }

    private var imageLimitBinding: Binding<Int> {
        Binding(
            get: { settings.imageLimit },
            set: { value in settings.setImageLimit(value) }
        )
    }

    private var textLimitBinding: Binding<Int> {
        Binding(
            get: { settings.textLimit },
            set: { value in settings.setTextLimit(value) }
        )
    }

    private var shortcutKeyBinding: Binding<UInt32> {
        Binding(
            get: { settings.shortcut.keyCode },
            set: { _ = settings.setShortcut(GlobalShortcut(
                keyCode: $0,
                modifiers: settings.shortcut.modifiers
            )) }
        )
    }

    private var shortcutModifiersBinding: Binding<UInt32> {
        Binding(
            get: { settings.shortcut.modifiers },
            set: { _ = settings.setShortcut(GlobalShortcut(
                keyCode: settings.shortcut.keyCode,
                modifiers: $0
            )) }
        )
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.destinationURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.setDestinationURL(url)
    }
}
