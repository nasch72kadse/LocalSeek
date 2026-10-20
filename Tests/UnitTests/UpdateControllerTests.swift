import Combine
import XCTest

@MainActor
private final class MockUpdateEngine: UpdateEngine {
    let changed = PassthroughSubject<Void, Never>()
    var changes: AnyPublisher<Void, Never> { changed.eraseToAnyPublisher() }
    var canCheck = true
    var automaticChecks = false
    var availableVersion: String?
    var lastCheck: Date?
    var includesPreviews = false
    var starts = 0
    var checks = 0
    func start() { starts += 1 }
    func check() { checks += 1; canCheck = false; changed.send() }
}

final class UpdateControllerTests: XCTestCase {
    @MainActor func testInitializationDoesNotStartNetworkingAndStartIsIdempotent() {
        let engine = MockUpdateEngine()
        let updates = UpdateController(engine: engine)
        XCTAssertEqual(engine.starts, 0)
        XCTAssertFalse(updates.canCheck)
        updates.checkForUpdates()
        XCTAssertEqual(engine.checks, 0)
        updates.start(); updates.start()
        XCTAssertEqual(engine.starts, 1)
        XCTAssertTrue(updates.canCheck)
    }

    @MainActor func testManualCheckWorksWithAutomaticChecksDisabledAndCannotStartTwice() {
        let engine = MockUpdateEngine()
        let updates = UpdateController(engine: engine)
        updates.start()
        XCTAssertFalse(updates.automaticChecks)
        updates.checkForUpdates(); updates.checkForUpdates()
        XCTAssertEqual(engine.checks, 1)
        XCTAssertFalse(updates.canCheck)
        engine.canCheck = true
        engine.lastCheck = Date(timeIntervalSince1970: 100)
        engine.availableVersion = "1.3.0"
        engine.changed.send()
        XCTAssertTrue(updates.canCheck)
        XCTAssertEqual(updates.lastCheck, engine.lastCheck)
        XCTAssertEqual(updates.availableVersion, "1.3.0")
    }

    @MainActor func testPreferencesAreReadWithoutOverwritingPersistedChoices() {
        let engine = MockUpdateEngine()
        engine.includesPreviews = true
        let updates = UpdateController(engine: engine)
        updates.start()
        XCTAssertFalse(engine.automaticChecks)
        XCTAssertTrue(updates.includesPreviews)
        updates.setAutomaticChecks(true)
        updates.setIncludesPreviews(false)
        XCTAssertTrue(engine.automaticChecks)
        XCTAssertFalse(engine.includesPreviews)
        engine.automaticChecks = false
        engine.changed.send()
        XCTAssertFalse(updates.automaticChecks)
    }
}
