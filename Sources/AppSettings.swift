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
        if let validationError = candidate.validationError {
            switch validationError {
            case .modifierRequired:
                shortcutErrorMessage = L10n.string("settings.shortcut-modifier-required")
            case .unsupportedShiftOptionOnly:
                shortcutErrorMessage = L10n.string("settings.shortcut-shift-option-unsupported")
            }
            return false
        }
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
    @ObservedObject private var settings: AppSettings

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
                ShortcutRecorderView(settings: settings)
                    .frame(width: 150, height: 28)
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

private struct ShortcutRecorderView: NSViewRepresentable {
    let settings: AppSettings

    func makeNSView(context: Context) -> ShortcutRecorderControl {
        let control = ShortcutRecorderControl()
        control.onShortcut = { [weak settings] keyCode, modifierFlags in
            guard let settings else { return }
            _ = settings.setShortcut(GlobalShortcut(
                keyCode: keyCode,
                modifierFlags: modifierFlags
            ))
        }
        return control
    }

    func updateNSView(_ control: ShortcutRecorderControl, context: Context) {
        control.shortcutDisplay = settings.shortcut.displayString
    }
}

final class ShortcutRecorderControl: NSButton {
    var onShortcut: ((UInt16, NSEvent.ModifierFlags) -> Void)?
    var shortcutDisplay = "" {
        didSet { if !isRecording { title = shortcutDisplay } }
    }
    private(set) var isRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
    }

    override var acceptsFirstResponder: Bool { true }

    @objc func beginRecording() {
        isRecording = true
        title = L10n.string("settings.shortcut-recording")
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        handleKeyDown(keyCode: event.keyCode, modifierFlags: event.modifierFlags)
    }

    func handleKeyDown(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        if keyCode == UInt16(kVK_Escape) {
            finishRecording()
            return
        }
        onShortcut?(keyCode, modifierFlags)
        finishRecording()
    }

    private func finishRecording() {
        isRecording = false
        title = shortcutDisplay
        window?.makeFirstResponder(nil)
    }
}
