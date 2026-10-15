import AppKit
import Carbon.HIToolbox
import Combine
import Foundation
import SwiftUI

struct ResolvedSecurityScopedBookmark {
    let url: URL
    let isStale: Bool
}

protocol SecurityScopedResourceAccess: AnyObject {
    func makeBookmark(for url: URL) throws -> Data
    func resolveBookmark(_ data: Data) throws -> ResolvedSecurityScopedBookmark
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

final class SystemSecurityScopedResourceAccess: SecurityScopedResourceAccess {
    func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func resolveBookmark(_ data: Data) throws -> ResolvedSecurityScopedBookmark {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return ResolvedSecurityScopedBookmark(url: url, isStale: isStale)
    }

    func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

final class SecurityScopedAccessLease: @unchecked Sendable {
    let url: URL

    private let access: any SecurityScopedResourceAccess
    private let lock = NSLock()
    private var destinationOwned = true
    private var historyReferenceCount = 0
    private var isAccessing: Bool

    init(url: URL, access: any SecurityScopedResourceAccess) {
        self.url = url
        self.access = access
        isAccessing = access.startAccessing(url)
    }

    func retainForHistory() {
        lock.withLock { historyReferenceCount += 1 }
    }

    func releaseFromHistory() {
        lock.withLock {
            precondition(historyReferenceCount > 0)
            historyReferenceCount -= 1
            stopIfUnused()
        }
    }

    func releaseDestinationOwnership() {
        lock.withLock {
            guard destinationOwned else { return }
            destinationOwned = false
            stopIfUnused()
        }
    }

    private func stopIfUnused() {
        guard !destinationOwned, historyReferenceCount == 0, isAccessing else { return }
        isAccessing = false
        access.stopAccessing(url)
    }

    deinit {
        if isAccessing {
            access.stopAccessing(url)
        }
    }
}

struct ImageDestinationSnapshot: @unchecked Sendable {
    private let saver: ImageFolderSaver
    let accessLease: SecurityScopedAccessLease?

    init(url: URL, accessLease: SecurityScopedAccessLease?) {
        saver = ImageFolderSaver(destinationDirectory: url)
        self.accessLease = accessLease
    }

    init(saver: ImageFolderSaver, accessLease: SecurityScopedAccessLease?) {
        self.saver = saver
        self.accessLease = accessLease
    }

    var url: URL { saver.destinationURL }

    func makeSaver() -> ImageFolderSaver {
        saver
    }
}

final class MutableImageDestination: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSnapshot: ImageDestinationSnapshot

    init(url: URL, accessLease: SecurityScopedAccessLease? = nil) {
        storedSnapshot = ImageDestinationSnapshot(url: url, accessLease: accessLease)
    }

    var url: URL {
        lock.withLock { storedSnapshot.url }
    }

    func update(to snapshot: ImageDestinationSnapshot) {
        lock.withLock { storedSnapshot = snapshot }
    }

    func snapshot() -> ImageDestinationSnapshot {
        lock.withLock { storedSnapshot }
    }
}

@MainActor
public final class AppSettings: ObservableObject {
    private enum Key {
        static let destinationPath = "settings.destinationPath"
        static let destinationBookmark = "settings.destinationBookmark"
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
    private let resourceAccess: any SecurityScopedResourceAccess
    private let picturesDirectory: URL
    private var historyStore: HistoryStore?
    private var hotKeyController: GlobalHotKeyController?
    private var imageDestination: MutableImageDestination?
    private var destinationAccessLease: SecurityScopedAccessLease?

    init(
        defaults: UserDefaults = .standard,
        resourceAccess: any SecurityScopedResourceAccess = SystemSecurityScopedResourceAccess(),
        picturesDirectory: URL = ImageFolderSaver.defaultDestinationDirectory()
            .deletingLastPathComponent()
    ) {
        self.defaults = defaults
        self.resourceAccess = resourceAccess
        self.picturesDirectory = picturesDirectory
        destinationAccessLease = nil

        if let bookmark = defaults.data(forKey: Key.destinationBookmark),
           let resolved = try? resourceAccess.resolveBookmark(bookmark) {
            destinationURL = resolved.url
            destinationAccessLease = SecurityScopedAccessLease(
                url: resolved.url,
                access: resourceAccess
            )
            if resolved.isStale,
               let refreshed = try? resourceAccess.makeBookmark(for: resolved.url) {
                defaults.set(refreshed, forKey: Key.destinationBookmark)
            }
        } else if let path = defaults.string(forKey: Key.destinationPath),
                  !path.isEmpty,
                  Self.isInsidePictures(
                      URL(fileURLWithPath: path, isDirectory: true),
                      picturesDirectory: picturesDirectory
                  ) {
            destinationURL = URL(fileURLWithPath: path, isDirectory: true)
            defaults.removeObject(forKey: Key.destinationBookmark)
        } else {
            destinationURL = ImageFolderSaver.defaultDestinationDirectory()
            defaults.removeObject(forKey: Key.destinationPath)
            defaults.removeObject(forKey: Key.destinationBookmark)
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
        imageDestination.update(to: ImageDestinationSnapshot(
            url: destinationURL,
            accessLease: destinationAccessLease
        ))
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

    @discardableResult
    public func setDestinationURL(_ url: URL) -> Bool {
        let standardizedURL = url.standardizedFileURL
        let bookmark: Data?
        let newLease: SecurityScopedAccessLease?

        if Self.isInsidePictures(
            standardizedURL,
            picturesDirectory: picturesDirectory
        ) {
            bookmark = nil
            newLease = nil
        } else {
            guard let createdBookmark = try? resourceAccess.makeBookmark(for: standardizedURL) else {
                return false
            }
            bookmark = createdBookmark
            newLease = SecurityScopedAccessLease(url: standardizedURL, access: resourceAccess)
        }

        let oldLease = destinationAccessLease
        destinationAccessLease = newLease
        destinationURL = standardizedURL
        defaults.set(standardizedURL.path, forKey: Key.destinationPath)
        if let bookmark {
            defaults.set(bookmark, forKey: Key.destinationBookmark)
        } else {
            defaults.removeObject(forKey: Key.destinationBookmark)
        }
        imageDestination?.update(to: ImageDestinationSnapshot(
            url: standardizedURL,
            accessLease: newLease
        ))
        oldLease?.releaseDestinationOwnership()
        return true
    }

    /// A nil URL represents a cancelled open panel and deliberately leaves all
    /// current destination state untouched.
    @discardableResult
    func applyDestinationSelection(_ url: URL?) -> Bool {
        guard let url else { return false }
        return setDestinationURL(url)
    }

    @discardableResult
    func setShortcut(_ candidate: GlobalShortcut) -> Bool {
        guard let hotKeyController else { return false }
        guard hotKeyController.updateShortcut(candidate) else {
            shortcutErrorMessage = L10n.string("settings.shortcut-error-message")
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

    private static func isInsidePictures(
        _ url: URL,
        picturesDirectory: URL
    ) -> Bool {
        let pictures = picturesDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .pathComponents
        let candidate = url
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .pathComponents
        return candidate.count >= pictures.count
            && Array(candidate.prefix(pictures.count)) == pictures
    }

    deinit {
        destinationAccessLease?.releaseDestinationOwnership()
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
            LabeledContent(L10n.string("settings.destination-folder")) {
                HStack {
                    Text(settings.destinationURL.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(L10n.string("settings.choose"), action: chooseDestination)
                }
            }
            Stepper(value: imageLimitBinding, in: 10...100) {
                Text(L10n.formatted("settings.image-history-count", settings.imageLimit))
            }
            Stepper(value: textLimitBinding, in: 10...100) {
                Text(L10n.formatted("settings.text-history-count", settings.textLimit))
            }
            LabeledContent(L10n.string("settings.shortcut")) {
                HStack {
                    Picker(L10n.string("settings.modifier-key"), selection: shortcutModifiersBinding) {
                        ForEach(Self.modifierChoices) { choice in
                            Text(choice.title).tag(choice.value)
                        }
                    }
                    .labelsHidden()
                    Picker(L10n.string("settings.key"), selection: shortcutKeyBinding) {
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
            L10n.string("settings.shortcut-error-title"),
            isPresented: Binding(
                get: { settings.shortcutErrorMessage != nil },
                set: { if !$0 { settings.shortcutErrorMessage = nil } }
            )
        ) {
            Button(L10n.string("common.ok"), role: .cancel) {}
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
        guard panel.runModal() == .OK else { return }
        _ = settings.applyDestinationSelection(panel.url)
    }
}
