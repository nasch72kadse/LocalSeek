import XCTest
@testable import SharedCore

final class StableHashTests: XCTestCase {
    func testDeterministicAndSensitive() {
        XCTAssertEqual(StableHash.hex("Risiko"), StableHash.hex("Risiko"))
        XCTAssertNotEqual(StableHash.hex("Risiko"), StableHash.hex("risiko"))
        XCTAssertEqual(StableHash.hex("Risiko").count, 64)
    }
}
