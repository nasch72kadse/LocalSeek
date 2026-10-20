import Foundation
import XCTest

final class SparkleUpdateEngineTests: XCTestCase {
    @MainActor func testStableBuildExcludesPreviewsAndPersistsExplicitOptIn() throws {
        try checkDefault(channel: "stable", expected: false)
    }

    @MainActor func testPreviewBuildIncludesPreviewsAndRespectsExplicitOptOut() throws {
        try checkDefault(channel: "dev", expected: true)
    }

    @MainActor private func checkDefault(channel: String, expected: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let contents = directory.appendingPathComponent("Fixture.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.localseek.fixture", "LocalSeekUpdateChannel": channel]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: contents.deletingLastPathComponent()))
        let suite = "com.localseek.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // No updater is started, no windows or network requests are created.
        let engine = SparkleUpdateEngine(defaults: defaults, bundle: bundle)
        XCTAssertEqual(engine.includesPreviews, expected)
        engine.includesPreviews = !expected
        let recreated = SparkleUpdateEngine(defaults: defaults, bundle: bundle)
        XCTAssertEqual(recreated.includesPreviews, !expected)
    }
}
