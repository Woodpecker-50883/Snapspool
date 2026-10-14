import Foundation
import XCTest
@testable import Snapspool

final class BuildArtifactConfigurationTests: XCTestCase {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testBuiltAppIsConfiguredAsAUIElement() throws {
        let infoURL = try builtAppURL()
            .appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: infoURL)
        let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
        let info = try XCTUnwrap(propertyList as? [String: Any])

        XCTAssertEqual(info["LSUIElement"] as? Bool, true)
    }

    func testBuiltAppContainsRequiredSandboxEntitlements() throws {
        let result = try run(
            "/usr/bin/codesign",
            arguments: ["--display", "--entitlements", "-", "--xml", try builtAppURL().path]
        )
        XCTAssertEqual(result.status, 0, result.standardError)

        let propertyList = try PropertyListSerialization.propertyList(
            from: Data(result.standardOutput.utf8),
            format: nil
        )
        let entitlements = try XCTUnwrap(propertyList as? [String: Any])
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

    func testBuiltExecutableRequiresMacOS15() throws {
        let executableURL = try builtAppURL()
            .appendingPathComponent("Contents/MacOS/Snapspool")
        let architecturesResult = try run(
            "/usr/bin/lipo",
            arguments: ["-archs", executableURL.path]
        )
        XCTAssertEqual(architecturesResult.status, 0, architecturesResult.standardError)
        let architectures = architecturesResult.standardOutput.split(whereSeparator: \.isWhitespace).map(String.init)
        XCTAssertFalse(architectures.isEmpty, "No architecture slices found in \(executableURL.path)")

        for architecture in architectures {
            let result = try run(
                "/usr/bin/xcrun",
                arguments: ["vtool", "-arch", architecture, "-show-build", executableURL.path]
            )
            XCTAssertEqual(result.status, 0, result.standardError)
            XCTAssertTrue(result.standardOutput.contains("platform MACOS"), "\(architecture):\n\(result.standardOutput)")
            XCTAssertNotNil(
                result.standardOutput.range(
                    of: #"(?m)^\s*minos 15\.0(?:\.0)?\s*$"#,
                    options: .regularExpression
                ),
                "\(architecture):\n\(result.standardOutput)"
            )
        }
    }

    func testGeneratedProjectAndBuildDirectoryAreIgnoredAndUntracked() throws {
        let generatedPaths = [
            "Snapspool.xcodeproj/project.pbxproj",
            "build/DerivedData",
        ]

        for path in generatedPaths {
            let ignored = try runGit(["check-ignore", "--quiet", "--no-index", path])
            XCTAssertEqual(ignored.status, 0, "Expected Git to ignore \(path)")

            let tracked = try runGit(["ls-files", "--", path])
            XCTAssertEqual(tracked.status, 0, tracked.standardError)
            XCTAssertTrue(
                tracked.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Generated path is tracked by Git: \(path)"
            )
        }
    }

    private func builtAppURL() throws -> URL {
        var directory = Bundle(for: Self.self).bundleURL

        for _ in 0..<8 {
            if directory.lastPathComponent == "Snapspool.app" {
                return directory
            }

            let sibling = directory
                .deletingLastPathComponent()
                .appendingPathComponent("Snapspool.app", isDirectory: true)
            if FileManager.default.fileExists(atPath: sibling.path) {
                return sibling
            }

            let parent = directory.deletingLastPathComponent()
            guard parent != directory else { break }
            directory = parent
        }

        return try XCTUnwrap(
            nil,
            "Could not locate the built Snapspool.app next to the test bundle at \(Bundle(for: Self.self).bundleURL.path)"
        )
    }

    private func runGit(_ arguments: [String]) throws -> CommandResult {
        try run(
            "/usr/bin/git",
            arguments: ["-C", projectRoot.path] + arguments
        )
    }

    private func run(_ executable: String, arguments: [String]) throws -> CommandResult {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        process.waitUntilExit()

        return CommandResult(
            status: process.terminationStatus,
            standardOutput: String(
                decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ),
            standardError: String(
                decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }
}

private struct CommandResult {
    let status: Int32
    let standardOutput: String
    let standardError: String
}
