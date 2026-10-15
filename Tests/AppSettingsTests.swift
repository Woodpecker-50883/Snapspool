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
        let resourceAccess = SettingsSecurityScopedResourceAccess()
        let initial = temporaryDirectory.appendingPathComponent("initial", isDirectory: true)
        let changed = temporaryDirectory.appendingPathComponent("changed", isDirectory: true)
        let destination = MutableImageDestination(url: initial)
        let service = ImageIngestionService(
            destinationProvider: { destination.snapshot() },
            fallbackSaver: ImageFolderSaver(
                destinationDirectory: temporaryDirectory.appendingPathComponent("fallback")
            ),
            notifier: SilentSettingsNotifier()
        )
        let store = HistoryStore(imageIngestionService: service)
        let settings = AppSettings(defaults: defaults, resourceAccess: resourceAccess)
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
        let relaunchedDestination = MutableImageDestination(
            url: ImageFolderSaver.defaultDestinationDirectory()
        )
        let relaunchedService = ImageIngestionService(
            destinationProvider: { relaunchedDestination.snapshot() },
            fallbackSaver: ImageFolderSaver(
                destinationDirectory: temporaryDirectory.appendingPathComponent("fallback-2")
            ),
            notifier: SilentSettingsNotifier()
        )
        let relaunchedStore = HistoryStore(imageIngestionService: relaunchedService)
        let relaunched = AppSettings(defaults: defaults, resourceAccess: resourceAccess)
        let relaunchedController = GlobalHotKeyController(
            registrar: SettingsHotKeyRegistrar(results: []),
            configuredShortcut: relaunched.shortcut
        ) {}
        relaunched.connect(
            historyStore: relaunchedStore,
            hotKeyController: relaunchedController,
            imageDestination: relaunchedDestination
        )
        let relaunchedIngested = await relaunchedService.ingest(.image(
            data: try makeTIFFData(),
            type: .tiff
        ))
        let relaunchedEntry = try XCTUnwrap(relaunchedIngested)

        XCTAssertEqual(relaunched.destinationURL, changed)
        XCTAssertEqual(relaunchedEntry.fileURL.deletingLastPathComponent(), changed)
        XCTAssertEqual(resourceAccess.bookmarkedURLs, [changed.standardizedFileURL])
        XCTAssertEqual(resourceAccess.resolvedBookmarks.count, 1)
    }

    func testDestinationPersistsThroughRealSecurityScopedBookmarkRoundTrip() throws {
        let destination = temporaryDirectory
            .appendingPathComponent("system-bookmark", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let systemAccess = SystemSecurityScopedResourceAccess()
        let settings = AppSettings(
            defaults: defaults,
            resourceAccess: systemAccess,
            picturesDirectory: temporaryDirectory.appendingPathComponent("Pictures")
        )

        guard settings.setDestinationURL(destination) else {
            throw XCTSkip("The current test sandbox cannot create security-scoped bookmarks")
        }
        let bookmark = try XCTUnwrap(defaults.data(forKey: "settings.destinationBookmark"))
        let resolved: ResolvedSecurityScopedBookmark
        do {
            resolved = try systemAccess.resolveBookmark(bookmark)
        } catch {
            throw XCTSkip("The current test sandbox cannot resolve security-scoped bookmarks: \(error)")
        }
        let relaunched = AppSettings(
            defaults: defaults,
            resourceAccess: systemAccess,
            picturesDirectory: temporaryDirectory.appendingPathComponent("Pictures")
        )

        XCTAssertEqual(
            resolved.url.resolvingSymlinksInPath().standardizedFileURL,
            destination.resolvingSymlinksInPath().standardizedFileURL
        )
        XCTAssertEqual(
            relaunched.destinationURL.resolvingSymlinksInPath().standardizedFileURL,
            destination.resolvingSymlinksInPath().standardizedFileURL
        )
    }

    func testCancelledDestinationSelectionKeepsExistingDestination() {
        let resourceAccess = SettingsSecurityScopedResourceAccess()
        let settings = AppSettings(defaults: defaults, resourceAccess: resourceAccess)
        let original = settings.destinationURL

        XCTAssertFalse(settings.applyDestinationSelection(nil))
        XCTAssertEqual(settings.destinationURL, original)
        XCTAssertTrue(resourceAccess.bookmarkedURLs.isEmpty)
        XCTAssertEqual(
            AppSettings(defaults: defaults, resourceAccess: resourceAccess).destinationURL,
            original
        )
    }

    func testPicturesContainmentResolvesSymlinkPointingInsidePictures() throws {
        let resourceAccess = SettingsSecurityScopedResourceAccess()
        let pictures = temporaryDirectory.appendingPathComponent("Pictures", isDirectory: true)
        let destination = pictures.appendingPathComponent("Destination", isDirectory: true)
        let link = temporaryDirectory.appendingPathComponent("linked-destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        let settings = AppSettings(
            defaults: defaults,
            resourceAccess: resourceAccess,
            picturesDirectory: pictures
        )

        XCTAssertTrue(settings.setDestinationURL(link))
        XCTAssertTrue(resourceAccess.bookmarkedURLs.isEmpty)
    }

    func testPicturesContainmentRejectsSymlinkPointingOutsidePictures() throws {
        let resourceAccess = SettingsSecurityScopedResourceAccess()
        let pictures = temporaryDirectory.appendingPathComponent("Pictures", isDirectory: true)
        let outside = temporaryDirectory.appendingPathComponent("Outside", isDirectory: true)
        let link = pictures.appendingPathComponent("apparent-destination", isDirectory: true)
        try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let settings = AppSettings(
            defaults: defaults,
            resourceAccess: resourceAccess,
            picturesDirectory: pictures
        )

        XCTAssertTrue(settings.setDestinationURL(link))
        XCTAssertEqual(resourceAccess.bookmarkedURLs, [link.standardizedFileURL])
    }

    func testOldDestinationAccessEndsOnlyAfterItsLastHistoryEntryIsRemoved() async throws {
        let resourceAccess = SettingsSecurityScopedResourceAccess()
        let oldDestination = temporaryDirectory.appendingPathComponent("old", isDirectory: true)
        let newDestination = temporaryDirectory.appendingPathComponent("new", isDirectory: true)
        let destination = MutableImageDestination(url: ImageFolderSaver.defaultDestinationDirectory())
        let service = ImageIngestionService(
            destinationProvider: { destination.snapshot() },
            fallbackSaver: ImageFolderSaver(
                destinationDirectory: temporaryDirectory.appendingPathComponent("fallback")
            ),
            notifier: SilentSettingsNotifier()
        )
        let store = HistoryStore(imageIngestionService: service)
        let settings = AppSettings(defaults: defaults, resourceAccess: resourceAccess)
        let controller = GlobalHotKeyController(
            registrar: SettingsHotKeyRegistrar(results: []),
            configuredShortcut: settings.shortcut
        ) {}
        settings.connect(
            historyStore: store,
            hotKeyController: controller,
            imageDestination: destination
        )

        XCTAssertTrue(settings.setDestinationURL(oldDestination))
        let firstIngested = await service.ingest(.image(
            data: try makeTIFFData(),
            type: .tiff
        ))
        let secondIngested = await service.ingest(.image(
            data: try makeTIFFData(),
            type: .tiff
        ))
        let firstOldEntry = try XCTUnwrap(firstIngested)
        let secondOldEntry = try XCTUnwrap(secondIngested)
        XCTAssertTrue(settings.setDestinationURL(newDestination))
        XCTAssertEqual(resourceAccess.stopCount(for: oldDestination), 0)

        await service.remove(firstOldEntry)
        XCTAssertEqual(resourceAccess.stopCount(for: oldDestination), 0)
        await service.remove(secondOldEntry)

        XCTAssertEqual(resourceAccess.stopCount(for: oldDestination), 1)
        XCTAssertEqual(resourceAccess.stopCount(for: newDestination), 0)
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

private final class SettingsSecurityScopedResourceAccess: SecurityScopedResourceAccess {
    private let lock = NSLock()
    private var stops: [URL: Int] = [:]
    private(set) var bookmarkedURLs: [URL] = []
    private(set) var resolvedBookmarks: [Data] = []

    func makeBookmark(for url: URL) throws -> Data {
        lock.withLock { bookmarkedURLs.append(url.standardizedFileURL) }
        return Data(url.standardizedFileURL.path.utf8)
    }

    func resolveBookmark(_ data: Data) throws -> ResolvedSecurityScopedBookmark {
        lock.withLock { resolvedBookmarks.append(data) }
        guard let path = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return ResolvedSecurityScopedBookmark(
            url: URL(fileURLWithPath: path, isDirectory: true),
            isStale: false
        )
    }

    func startAccessing(_ url: URL) -> Bool { true }

    func stopAccessing(_ url: URL) {
        lock.withLock { stops[url.standardizedFileURL, default: 0] += 1 }
    }

    func stopCount(for url: URL) -> Int {
        lock.withLock { stops[url.standardizedFileURL, default: 0] }
    }
}
