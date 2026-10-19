import XCTest
import SharedCore

/// Optional auf Rechnern ohne Modell; führt mit lokal installiertem Q8-Modell echte
/// Inferenz aus. Nur synthetische Dokumente, isolierte DBs und temporäre Quellen.
final class RealEmbeddingTests: XCTestCase {
    private func modelURL() throws -> URL {
        let url: URL
        if let path = ProcessInfo.processInfo.environment["LOCALSEEK_TEST_MODEL"] {
            url = URL(fileURLWithPath: path)
        } else {
            url = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/LocalSeek/models/multilingual-e5-small-q8_0.gguf")
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw XCTSkip("Kein lokales Echt-Modell für den Integrationstest installiert")
        }
        return url
    }

    private static func fixture() async throws -> (db: IndexDatabase, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("localseek-real-\(UUID().uuidString)")
        let sourceURL = root.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try Data("The invoice must be paid within thirty days. Bank transfer is accepted.".utf8)
            .write(to: sourceURL.appendingPathComponent("payment.txt"))
        try Data("Tomatoes need sunlight and regular watering in the garden.".utf8)
            .write(to: sourceURL.appendingPathComponent("garden.txt"))
        let db = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let source = SourceRecord(id: sourceURL.path, path: sourceURL.path)
        try db.upsertSource(source)
        try DirectoryScanner().scan(source: source, into: db)
        try await ContentIndexer().indexContent(source: source, into: db)
        return (db, root)
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(predicate(), "Erwarteter Indizierungszustand wurde nicht erreicht")
    }

    func testRealVectorsAreNormalizedDeterministicAndCrossLingual() async throws {
        let provider = LlamaEmbeddingProvider(modelURL: try modelURL())
        let passages = try await provider.embed([
            "The invoice must be paid within thirty days. Bank transfer is accepted.",
            "Tomatoes need sunlight and regular watering in the garden."
        ], kind: .passage)
        let query = try await provider.embed(["Wann muss ich die Rechnung bezahlen?"], kind: .query)[0]
        let repeated = try await provider.embed(["Wann muss ich die Rechnung bezahlen?"], kind: .query)[0]
        for vector in passages + [query] {
            XCTAssertEqual(vector.count, 384)
            XCTAssertTrue(vector.allSatisfy(\.isFinite))
            XCTAssertEqual(vector.reduce(0) { $0 + $1 * $1 }, 1, accuracy: 0.0001)
        }
        XCTAssertLessThan(zip(query, repeated).map { abs($0 - $1) }.max() ?? 1, 0.0001)
        let relevant = zip(query, passages[0]).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        let unrelated = zip(query, passages[1]).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        XCTAssertGreaterThan(relevant, unrelated)
        await provider.unload()
    }

    func testBatchedSequencesMatchIndependentEncoding() async throws {
        let provider = LlamaEmbeddingProvider(modelURL: try modelURL())
        let texts = ["Rechnung bezahlen", "Tomatoes in the garden", "日本語 Vertrag 🧑🏽‍💻",
                     String(repeating: "payment contract ", count: 200)]
        let together = try await provider.embed(texts, kind: .passage)
        var separate: [[Float]] = []
        for text in texts { separate.append(try await provider.embed([text], kind: .passage)[0]) }
        XCTAssertEqual(together.count, texts.count)
        for (batch, single) in zip(together, separate) {
            let cosine = zip(batch, single).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            XCTAssertGreaterThan(cosine, 0.9999, "Independent sequence masks and pooling must be preserved")
        }
        await provider.unload()
    }

    func testActualTokenizerChunksPreserveLongUnicodeTail() async throws {
        let provider = LlamaEmbeddingProvider(modelURL: try modelURL())
        let text = String(repeating: "Rechnung 日本語 🧑🏽‍💻 payment insurance ", count: 250) + "LAST_MARKER"
        do {
            let chunks = try await DocumentChunker(tokenizer: provider).chunks(from: .init(segments: [.init(text: text, location: .page(8))]), fileId: 1)
            XCTAssertGreaterThan(chunks.count, 5)
            XCTAssertTrue(chunks.last?.text.hasSuffix("LAST_MARKER") == true)
            for chunk in chunks {
                let count = try await provider.countTokens(in: chunk.text)
                XCTAssertLessThanOrEqual(count, 350); XCTAssertEqual(count, chunk.tokenCount)
            }
            await provider.unload()
        } catch { await provider.unload(); throw error }
    }

    @MainActor
    func testStartupCatchUpEmbedsExistingContent() async throws {
        let model = try modelURL()
        let (db, root) = try await Self.fixture()
        let service = IndexService(database: db, modelURL: model,
                                   control: IndexControl(environment: { ResourceSnapshot() }))
        addTeardownBlock {
            await service.shutdown()
            try db.dbPool.close()
            try FileManager.default.removeItem(at: root)
        }
        try await waitUntil { service.status.embeddingCount == 2 }
        XCTAssertTrue(service.hasEmbeddingModel)
        XCTAssertNil(service.lastError)
        let hits = await service.searchContentAsync("Wann muss ich die Rechnung bezahlen?", strategy: .semantic)
        XCTAssertEqual(hits.first?.filename, "payment.txt")
    }

    func testLongInputsRespectModelContextAndAllowReuse() async throws {
        let provider = LlamaEmbeddingProvider(modelURL: try modelURL())
        let longText = String(repeating: "Rechnung Zahlung Vertrag ", count: 2000)
        let passage = try await provider.embed([longText], kind: .passage)[0]
        let query = try await provider.embed([longText], kind: .query)[0]
        let following = try await provider.embed(["Rechnung bezahlen"], kind: .query)[0]
        for vector in [passage, query, following] {
            XCTAssertEqual(vector.count, 384)
            XCTAssertTrue(vector.allSatisfy(\.isFinite))
            XCTAssertEqual(vector.reduce(0) { $0 + $1 * $1 }, 1, accuracy: 0.0001)
        }
        await provider.unload()
    }

    @MainActor
    func testInstallingModelImmediatelyEmbedsExistingContent() async throws {
        let model = try modelURL()
        let (db, root) = try await Self.fixture()
        let service = IndexService(database: db, modelURL: root.appendingPathComponent("missing.gguf"),
                                   control: IndexControl(environment: { ResourceSnapshot() }))
        addTeardownBlock {
            await service.shutdown()
            try db.dbPool.close()
            try FileManager.default.removeItem(at: root)
        }
        try await waitUntil { service.lastError != nil }
        XCTAssertFalse(service.hasEmbeddingModel)
        service.installModel(from: model)
        try await waitUntil { service.status.embeddingCount == 2 }
        XCTAssertEqual(try db.activeModel()?.name, model.lastPathComponent)
        XCTAssertNil(service.lastError)
    }

    @MainActor
    func testInvalidModelIsReportedAndExactSearchRemainsAvailable() async throws {
        let (db, root) = try await Self.fixture()
        let invalid = root.appendingPathComponent("invalid.gguf")
        try Data("invalid GGUF fixture".utf8).write(to: invalid)
        let service = IndexService(database: db, modelURL: invalid,
                                   control: IndexControl(environment: { ResourceSnapshot() }))
        addTeardownBlock {
            await service.shutdown()
            try db.dbPool.close()
            try FileManager.default.removeItem(at: root)
        }
        try await waitUntil { service.lastError != nil }
        XCTAssertTrue(service.lastError?.contains("llama.cpp-kompatible") == true)
        XCTAssertFalse(service.hasEmbeddingModel)
        XCTAssertNil(try db.activeModel())
        let hits = await service.searchContentAsync("invoice", strategy: .exact)
        XCTAssertEqual(hits.first?.filename, "payment.txt")
    }
}
