import XCTest

final class ProjectConfigurationTests: XCTestCase {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testAppIsConfiguredAsAUIElement() throws {
        let info = try propertyList(named: "Info.plist")
        XCTAssertEqual(info["LSUIElement"] as? Bool, true)
    }

    func testRequiredSandboxEntitlementsAreEnabled() throws {
        let entitlements = try propertyList(named: "Snapspool.entitlements")
        let requiredKeys = [
            "com.apple.security.app-sandbox",
            "com.apple.security.assets.pictures.read-write",
            "com.apple.security.files.user-selected.read-write",
            "com.apple.security.files.bookmarks.app-scope",
        ]

        for key in requiredKeys {
            XCTAssertEqual(entitlements[key] as? Bool, true, "Missing entitlement: \(key)")
        }
    }

    private func propertyList(named name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: projectRoot.appendingPathComponent(name))
        let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(propertyList as? [String: Any])
    }
}
