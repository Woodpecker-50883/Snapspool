import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Snapspool

@MainActor
final class AppSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var temporaryDirectory: URL!

    override func setUp() {
        super.setUp()
        suiteName = "AppSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: temporaryDirectory)
        super.tearDown()
    }

    func testLimitsApplyImmediatelyAndAreLoadedByNextLaunch() {
        let store = makeHistoryStore()
        for index in 0..<11 {
            store.recordDetection(of: .text(data: Data("text-\(index)".utf8)))
        }
        let settings = AppSettings(defaults: defaults)
        connect(settings, to: store, registrar: SettingsHotKeyRegistrar(results: []))

        settings.setTextLimit(10)
        settings.setImageLimit(42)

        XCTAssertEqual(store.textCount, 10)
        XCTAssertEqual(store.textLimit, 10)
        XCTAssertEqual(store.imageLimit, 42)

        let relaunched = AppSettings(defaults: defaults)
        XCTAssertEqual(relaunched.textLimit, 10)
        XCTAssertEqual(relaunched.imageLimit, 42)
    }

    func testDestinationChangeAffectsNextRealImageSaveAndPersists() async throws {
        let initial = temporaryDirectory.appendingPathComponent("initial", isDirectory: true)
        let changed = temporaryDirectory.appendingPathComponent("changed", isDirectory: true)
        let destination = MutableImageDestination(url: initial)
        let service = ImageIngestionService(
            destinationSaverProvider: { destination.makeSaver() },
            fallbackSaver: ImageFolderSaver(
                destinationDirectory: temporaryDirectory.appendingPathComponent("fallback")
            ),
            notifier: SilentSettingsNotifier()
        )
        let store = HistoryStore(imageIngestionService: service)
        let settings = AppSettings(defaults: defaults)
        let controller = GlobalHotKeyController(
            registrar: SettingsHotKeyRegistrar(results: []),
            configuredShortcut: settings.shortcut
        ) {}
        settings.connect(
            historyStore: store,
            hotKeyController: controller,
            imageDestination: destination
        )

        settings.setDestinationURL(changed)
        let ingested = await service.ingest(.image(
            data: try makeTIFFData(),
            type: .tiff
        ))
        let entry = try XCTUnwrap(ingested)

        XCTAssertEqual(entry.fileURL.deletingLastPathComponent(), changed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: initial.path))
        XCTAssertEqual(AppSettings(defaults: defaults).destinationURL, changed)
    }

    func testSuccessfulShortcutChangeRegistersAndPersists() {
        let registrar = SettingsHotKeyRegistrar(results: [true])
        let store = makeHistoryStore()
        let settings = AppSettings(defaults: defaults)
        connect(settings, to: store, registrar: registrar)
        let candidate = GlobalShortcut(
            keyCode: UInt32(kVK_ANSI_B),
            modifiers: UInt32(cmdKey | optionKey)
        )

        XCTAssertTrue(settings.setShortcut(candidate))
        XCTAssertEqual(registrar.attempts, [candidate])
        XCTAssertEqual(AppSettings(defaults: defaults).shortcut, candidate)
        XCTAssertNil(settings.shortcutErrorMessage)
    }

    func testFailedShortcutChangeRestoresOldRegistrationAndIsNotPersisted() {
        let registrar = SettingsHotKeyRegistrar(results: [false, true])
        let store = makeHistoryStore()
        let settings = AppSettings(defaults: defaults)
        let original = settings.shortcut
        connect(settings, to: store, registrar: registrar)
        let rejected = GlobalShortcut(
            keyCode: UInt32(kVK_ANSI_X),
            modifiers: UInt32(controlKey | optionKey)
        )

        XCTAssertFalse(settings.setShortcut(rejected))
        XCTAssertEqual(registrar.attempts, [rejected, original])
        XCTAssertEqual(settings.shortcut, original)
        XCTAssertEqual(AppSettings(defaults: defaults).shortcut, original)
        XCTAssertNotNil(settings.shortcutErrorMessage)
    }

    private func connect(
        _ settings: AppSettings,
        to store: HistoryStore,
        registrar: SettingsHotKeyRegistrar
    ) {
        let controller = GlobalHotKeyController(
            registrar: registrar,
            configuredShortcut: settings.shortcut
        ) {}
        settings.connect(
            historyStore: store,
            hotKeyController: controller,
            imageDestination: MutableImageDestination(url: settings.destinationURL)
        )
    }

    private func makeHistoryStore() -> HistoryStore {
        HistoryStore(imageIngestionService: ImageIngestionService(
            destinationSaver: ImageFolderSaver(
                destinationDirectory: temporaryDirectory.appendingPathComponent("images")
            ),
            fallbackSaver: ImageFolderSaver(
                destinationDirectory: temporaryDirectory.appendingPathComponent("fallback")
            ),
            notifier: SilentSettingsNotifier()
        ))
    }

    private func makeTIFFData() throws -> Data {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        return try XCTUnwrap(image.tiffRepresentation)
    }
}

@MainActor
private final class SettingsHotKeyRegistrar: GlobalHotKeyRegistering {
    private var results: [Bool]
    private(set) var attempts: [GlobalShortcut] = []

    init(results: [Bool]) {
        self.results = results
    }

    func register(
        _ shortcut: GlobalShortcut,
        handler: @MainActor @Sendable @escaping () -> Void
    ) -> Bool {
        attempts.append(shortcut)
        return results.isEmpty ? true : results.removeFirst()
    }

    func unregister() {}
}

private struct SilentSettingsNotifier: ImageSaveNotifying {
    func notifyDestinationSaveFailed() {}
    func notifyFallbackSaveFailed() {}
}
