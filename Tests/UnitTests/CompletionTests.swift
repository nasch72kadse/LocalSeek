import XCTest
import GRDB
import ZIPFoundation
@testable import SharedCore

final class CompletionTests: XCTestCase {
    private func file(_ contents: String, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
        try Data(contents.utf8).write(to: url); addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func database() throws -> IndexDatabase {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("completion-" + UUID().uuidString)
        let db = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        addTeardownBlock { try db.dbPool.close(); try FileManager.default.removeItem(at: root) }; return db
    }
    func testHTMLExcludesExecutableAndRemoteContentAndDecodesEntities() throws {
        let url = try file("<html><head><script>secret</script></head><body><p>Rechnung &amp; Zahlung &#252;berfällig</p><!-- hidden > comment --><img src='https://invalid.test/a'><style>hidden</style><div>Ende</div></body></html>", ext: "html")
        let result = try HTMLExtractor().extract(fileURL: url, context: .init())
        XCTAssertEqual(result.segments.first?.text, "Rechnung & Zahlung überfällig\nEnde")
    }
    func testEmailPrefersPlainTextDecodesSubjectAndSkipsAttachment() throws {
        let url = try file("""
        Subject: =?UTF-8?B?UmVjaG51bmc=?=
        Content-Type: multipart/mixed; boundary="outer"

        --outer
        Content-Type: multipart/alternative; boundary=inner

        --inner
        Content-Type: text/plain; charset=UTF-8
        Content-Transfer-Encoding: quoted-printable

        Bitte =C3=BCberweisen.
        --inner
        Content-Type: text/html

        <b>Duplicate</b>
        --inner--
        --outer
        Content-Type: text/plain
        Content-Disposition: attachment; filename=secret.txt

        SECRET
        --outer--
        """, ext: "eml")
        let result = try EMLExtractor().extract(fileURL: url, context: .init())
        XCTAssertEqual(result.title, "Rechnung")
        XCTAssertEqual(result.segments.last?.text, "Bitte überweisen.")
        XCTAssertFalse(result.segments.contains { $0.text.contains("SECRET") || $0.text.contains("Duplicate") })
    }
    func testRTFAndOversizedText() throws {
        let url = try file("{\\rtf1\\ansi Rechnung \\b bezahlt\\b0 .}", ext: "rtf")
        XCTAssertTrue(try RTFExtractor().extract(fileURL: url, context: .init()).segments[0].text.contains("bezahlt"))
        XCTAssertThrowsError(try PlainTextExtractor().extract(fileURL: file("123456", ext: "txt"), context: .init(maxBytes: 5)))
    }
    private func zip(_ xml: String, context: ExtractionContext = .init()) throws -> ExtractedDocument {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".docx")
        let archive = try Archive(url: url, accessMode: .create); let data = Data(xml.utf8)
        try archive.addEntry(with: "word/document.xml", type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { offset, count in data.subdata(in: Int(offset)..<min(Int(offset) + count, data.count)) }
        defer { try? FileManager.default.removeItem(at: url) }
        return try DOCXExtractor().extract(fileURL: url, context: context)
    }
    func testOOXMLRejectsDTDAndExpansionLimits() throws {
        XCTAssertThrowsError(try zip("<!DOCTYPE x [<!ENTITY x 'boom'>]><w:p xmlns:w='w'><w:t>&x;</w:t></w:p>"))
        XCTAssertThrowsError(try zip("<w:p xmlns:w='w'><w:t>" + String(repeating: "a", count: 1000) + "</w:t></w:p>", context: .init(maxBytes: 100)))
        XCTAssertThrowsError(try zip("<broken>"))
    }
    func testDOCXRetainsHeadingTableAndSection() throws {
        let result = try zip("<w:document xmlns:w='w'><w:p><w:pPr><w:pStyle w:val='Heading1'/></w:pPr><w:r><w:t>Risiken</w:t></w:r></w:p><w:tbl><w:p><w:r><w:t>Ausfall</w:t></w:r></w:p></w:tbl></w:document>")
        XCTAssertEqual(result.segments.map(\.kind), [.heading, .table])
        XCTAssertEqual(result.segments.last?.location, .section("Risiken"))
    }
    func testFiltersApplyBeforeSemanticTopKAndCachedFavoritesPersist() async throws {
        struct Provider: EmbeddingProvider {
            let dimensions = 2
            func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]] { texts.map { _ in [1, 0] } }
        }
        let db = try database(); let store = BruteForceVectorStore(db: db)
        try db.upsertSource(SourceRecord(id: "s", path: "/tmp/s"))
        for i in 0..<5 {
            try db.upsertFile(FileRecord(sourceId: "s", relativePath: "scope/report\(i).\(i == 4 ? "pdf" : "txt")", filename: "report\(i)", fileExtension: i == 4 ? "pdf" : "txt", size: Int64(i * 1000), mtime: Date(timeIntervalSince1970: Double(i) * 1000), state: i == 4 ? "cloudOnly" : "present"))
            let id = try await db.dbPool.read { try Int64.fetchOne($0, sql: "SELECT max(id) FROM files")! }
            try db.replaceChunks(fileId: id, chunks: [ChunkRecord(fileId: id, ordinal: 0, text: "invoice information")])
            let chunk = try await db.dbPool.read { try Int64.fetchOne($0, sql: "SELECT max(id) FROM chunks")! }
            try store.upsert(chunkId: chunk, modelId: "m", textHash: "h", embedding: [Float(5-i), Float(i)])
            if i == 4 { try db.toggleFavorite(fileId: id) }
        }
        let filter = SearchFilters(extensions: ["pdf"], pathContains: "scope", after: Date(timeIntervalSince1970: 3000), minimumBytes: 3500, favoritesOnly: true)
        let engine = HybridSearchEngine(db: db, provider: Provider(), store: store, modelId: "m")
        for strategy in [SearchStrategy.exact, .semantic, .hybrid] {
            let hits = try await engine.search("invoice", strategy: strategy, limit: 1, filters: filter)
            XCTAssertEqual(hits.count, 1); XCTAssertEqual(hits.first?.filename, "report4"); XCTAssertEqual(hits.first?.fileState, "cloudOnly")
        }
        XCTAssertEqual(try db.searchFilenames("", filters: filter).count, 1)
        try db.setSourceScanStatus(id: "s", status: "unavailable", lastScan: nil)
        XCTAssertEqual(try db.favoriteIDs().count, 1)
    }
    func testIntegrityRepairsDerivedContentAndInvalidVectorsOnly() throws {
        let db = try database(); try db.upsertSource(SourceRecord(id: "s", path: "/tmp/s"))
        try db.upsertFile(FileRecord(sourceId: "s", relativePath: "a.txt", filename: "a.txt", fileExtension: "txt", size: 1, mtime: nil))
        let id = try db.dbPool.read { try Int64.fetchOne($0, sql: "SELECT id FROM files")! }
        try db.replaceChunks(fileId: id, chunks: [ChunkRecord(fileId: id, ordinal: 0, text: "important invoice")])
        try db.dbPool.write { db in
            try db.execute(sql: "DELETE FROM chunk_fts")
            try db.execute(sql: "INSERT INTO chunk_vectors_v1(chunkId,modelId,textHash,embedding,norm) SELECT id,'m','h',x'0102',0 FROM chunks")
        }
        let health = try db.checkIntegrity()
        XCTAssertTrue(health.repairedFTS); XCTAssertEqual(health.removedInvalidVectors, 1)
        XCTAssertEqual(try db.searchChunks("invoice").count, 1)
        XCTAssertEqual(try db.chunkCount(), 1)
        let attrs = try FileManager.default.attributesOfItem(atPath: db.storageURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testResourcePolicyDefersHeavyWorkAndPauseIsCancelable() async throws {
        let control = IndexControl(pauseHeavyOnBattery: true, environment: { .init(onBattery: true) })
        try await control.checkpoint(.extraction)
        do { try await control.checkpoint(.embedding); XCTFail("Expected battery defer") } catch let error as ResourceDeferred { XCTAssertEqual(error.reason, .battery) }
        let hot = IndexControl(environment: { .init(thermalLevel: 2) })
        do { try await hot.checkpoint(.extraction); XCTFail("Expected thermal defer") } catch let error as ResourceDeferred { XCTAssertEqual(error.reason, .temperature) }
        await control.setPaused(true)
        do { try await control.checkpoint(.metadata); XCTFail("Expected pause") } catch is CancellationError { }
    }
    func testCancelledJobCannotEnqueueFollowUpsAndFailuresAreBounded() throws {
        let db = try database(); try db.upsertSource(SourceRecord(id: "s", path: "/tmp/s"))
        try db.enqueueJobs([.init(sourceId: "s", kind: .metadata)])
        let job = try XCTUnwrap(try db.claimNextJob())
        try db.cancelJobs(sourceId: "s")
        try db.finishJob(job, followUps: [.init(sourceId: "s", kind: .content)])
        XCTAssertNil(try db.claimNextJob())
        try db.upsertFile(FileRecord(sourceId: "s", relativePath: "a.txt", filename: "a.txt", fileExtension: "txt", size: 1, mtime: nil))
        let id = try XCTUnwrap(try db.searchFilenames("a.txt").first?.id)
        for _ in 0..<5 { try db.recordExtractionFailure(fileId: id, code: "fixture", now: Date(timeIntervalSince1970: 0)) }
        XCTAssertTrue(try db.filesNeedingContentExtraction(sourceId: "s", extensions: ["txt"]).isEmpty)
        try db.clearExtractionFailures(sourceId: "s")
        XCTAssertEqual(try db.filesNeedingContentExtraction(sourceId: "s", extensions: ["txt"]).count, 1)
    }
    func testDurableJobsSurviveClosingAndReopeningDatabase() throws {
        let db = try database(); let url = db.storageURL
        try db.upsertSource(SourceRecord(id: "s", path: "/tmp/s"))
        try db.enqueueJobs([.init(sourceId: "s", kind: .content), .init(sourceId: "s", kind: .metadata)])
        XCTAssertEqual(try db.claimNextJob()?.kind, .metadata)
        XCTAssertFalse(try db.hasHigherPriorityJob(than: 0))
        try db.dbPool.close()
        let reopened = try IndexDatabase(url: url)
        defer { try? reopened.dbPool.close() }
        try reopened.recoverInterruptedJobs()
        XCTAssertTrue(try reopened.hasHigherPriorityJob(than: 10))
        XCTAssertEqual(try reopened.claimNextJob()?.kind, .metadata)
    }

    func testHTMLRetainsBodyAfterScriptComparisonsAndManyEntities() {
        let html = "<script>if (a < b && c > d) { x = 1; }</script><p>Visible &amp; &#XFC;ber</p>" + String(repeating: "&amp;", count: 2000)
        let text = HTMLExtractor.text(from: html)
        XCTAssertTrue(text.hasPrefix("Visible & über\n"))
        XCTAssertTrue(text.hasSuffix(String(repeating: "&", count: 2000)))
        XCTAssertFalse(text.contains("if (a"))
    }
    func testMIMEBoundaryEndingWithDashesAndWhitespace() throws {
        let url = try file("Content-Type: multipart/mixed; boundary=mail--\n\n--mail--  \nContent-Type: text/plain\n\nVisible message\n--mail----\n", ext: "eml")
        let result = try EMLExtractor().extract(fileURL: url, context: .init())
        XCTAssertEqual(result.segments.first?.text, "Visible message")
    }
    func testHardLinksStayDistinctWithOpaqueSourceID() throws {
        let db = try database()
        let root = db.storageURL.deletingLastPathComponent().appendingPathComponent("source")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("invoice".utf8).write(to: root.appendingPathComponent("a.txt"))
        try FileManager.default.linkItem(at: root.appendingPathComponent("a.txt"), to: root.appendingPathComponent("b.txt"))
        let source = SourceRecord(id: "opaque-source", path: root.path)
        try db.upsertSource(source); try DirectoryScanner().scan(source: source, into: db)
        XCTAssertEqual(try db.fileCount(), 2)
        XCTAssertEqual(try db.searchFilenames(".txt").count, 2)
    }
    func testCancellationDuringStatusCallbackPreventsWorkerStart() async throws {
        actor Once {
            var first = true
            func take() -> Bool { defer { first = false }; return first }
        }
        actor Counter {
            var value = 0
            func increment() { value += 1 }
        }
        let db = try database(); try db.upsertSource(SourceRecord(id: "s", path: "/tmp/s"))
        let once = Once(), counter = Counter()
        let scheduler = IndexScheduler(db: db, control: IndexControl(environment: { .init() })) { _, _ in
            await counter.increment(); return []
        }
        await scheduler.setOnChange {
            if await once.take() { try? await scheduler.cancel(sourceId: "s") }
        }
        try await scheduler.enqueue([.init(sourceId: "s", kind: .metadata)])
        let beforeStart = await counter.value
        XCTAssertEqual(beforeStart, 0)
        try await scheduler.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while try db.jobCounts().pending + db.jobCounts().running > 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await scheduler.stop(); await scheduler.setOnChange { }
        let runs = await counter.value
        XCTAssertEqual(runs, 0)
        XCTAssertNil(try db.claimNextJob())
    }

    func testScannerStopsImmediatelyAfterBatchWriteFailure() throws {
        final class Count: @unchecked Sendable {
            private let lock = NSLock(); private var calls = 0
            func increment() { lock.lock(); calls += 1; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return calls }
        }
        struct Metadata: FileMetadataProviding {
            let count: Count
            func metadata(for url: URL) throws -> LocalFileMetadata {
                count.increment(); return try LocalFileMetadataProvider().metadata(for: url)
            }
        }
        let db = try database()
        let root = db.storageURL.deletingLastPathComponent().appendingPathComponent("source")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<5 { try Data("fixture".utf8).write(to: root.appendingPathComponent("\(i).txt")) }
        let source = SourceRecord(id: root.path, path: root.path)
        try db.upsertSource(source)
        try db.dbPool.write { try $0.execute(sql: "CREATE TRIGGER fail_file_insert BEFORE INSERT ON files BEGIN SELECT RAISE(ABORT, 'test'); END") }
        let count = Count()
        XCTAssertThrowsError(try DirectoryScanner(metadata: Metadata(count: count)).scan(source: source, into: db, batchSize: 1))
        XCTAssertEqual(count.value, 2, "Only root and the first file should be inspected after a failed write")
    }
    func testWatcherCanStopInsideItsOwnCallback() throws {
        final class Holder: @unchecked Sendable {
            private let lock = NSLock(); private var watcher: FSEventsWatcher?
            func set(_ value: FSEventsWatcher?) { lock.lock(); watcher = value; lock.unlock() }
            func stop() { lock.lock(); let value = watcher; lock.unlock(); value?.stop() }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("watcher-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let finished = expectation(description: "Reentrant watcher stop")
        let holder = Holder()
        let watcher = FSEventsWatcher(latency: 0.01) { _ in holder.stop(); finished.fulfill() }
        holder.set(watcher); watcher.start(paths: [root.path])
        try Data("fixture".utf8).write(to: root.appendingPathComponent("event.txt"))
        wait(for: [finished], timeout: 5)
        watcher.stop(); holder.set(nil)
    }

}
