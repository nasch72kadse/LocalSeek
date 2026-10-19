import XCTest

final class ModelLocatorTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSelectionPrefersActiveModelAndOtherwiseIsStable() throws {
        let dir = try directory()
        for name in ["z.gguf", "a.gguf", "not-a-model.txt"] {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        XCTAssertEqual(try ModelLocator.installedModel(in: dir)?.lastPathComponent, "a.gguf")
        XCTAssertEqual(try ModelLocator.installedModel(preferredName: "z.gguf", in: dir)?.lastPathComponent, "z.gguf")
    }

    func testSelectingInstalledFileDoesNotDeleteIt() throws {
        let dir = try directory()
        let url = dir.appendingPathComponent("model.gguf")
        let bytes = Data("model fixture".utf8)
        try bytes.write(to: url)
        XCTAssertEqual(try ModelLocator.install(from: url, into: dir), url)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testFailedCopyPreservesExistingModel() throws {
        let dir = try directory()
        let existing = dir.appendingPathComponent("model.gguf")
        let bytes = Data("existing model".utf8)
        try bytes.write(to: existing)
        let missing = try directory().appendingPathComponent("model.gguf")
        XCTAssertThrowsError(try ModelLocator.install(from: missing, into: dir))
        XCTAssertEqual(try Data(contentsOf: existing), bytes)
    }

    func testReplacementPreservesSourceAndInstallsNewFile() throws {
        let dir = try directory()
        let source = try directory().appendingPathComponent("model.gguf")
        let dest = dir.appendingPathComponent("model.gguf")
        try Data("old model".utf8).write(to: dest)
        let bytes = Data("new model".utf8)
        try bytes.write(to: source)
        _ = try ModelLocator.install(from: source, into: dir)
        XCTAssertEqual(try Data(contentsOf: dest), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }
}
