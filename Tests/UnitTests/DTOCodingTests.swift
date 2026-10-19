import XCTest
@testable import SharedCore

/// Verifiziert die schlanken Sendable-Modelle (nach dem Umbau auf Ein-Prozess:
/// keine XPC-Serialisierung mehr, daher reine Wert-/Gleichheitstests).
final class DTOCodingTests: XCTestCase {

    func testSourceStatusValues() {
        let s = SourceStatusDTO(id: "/tmp/Audits", displayPath: "Audits",
                                state: .scanning, fileCount: 42)
        XCTAssertEqual(s.id, "/tmp/Audits")
        XCTAssertEqual(s.displayPath, "Audits")
        XCTAssertEqual(s.state, .scanning)
        XCTAssertEqual(s.fileCount, 42)
    }

    func testSourceStatusEquatable() {
        let a = SourceStatusDTO(id: "x", displayPath: "X", state: .idle, fileCount: 1)
        let b = SourceStatusDTO(id: "x", displayPath: "X", state: .idle, fileCount: 1)
        let c = SourceStatusDTO(id: "x", displayPath: "X", state: .error, fileCount: 1)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testIndexStatusValues() {
        let i = IndexStatusDTO(fileCount: 10, chunkCount: 20,
                               embeddingCount: 5, sourceCount: 2, isPaused: true)
        XCTAssertEqual(i.fileCount, 10)
        XCTAssertEqual(i.chunkCount, 20)
        XCTAssertEqual(i.embeddingCount, 5)
        XCTAssertEqual(i.sourceCount, 2)
        XCTAssertTrue(i.isPaused)
    }

    func testIndexStatusEmpty() {
        let e = IndexStatusDTO.empty
        XCTAssertEqual(e.fileCount, 0)
        XCTAssertEqual(e.sourceCount, 0)
        XCTAssertFalse(e.isPaused)
    }
}
