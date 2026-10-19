import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import GRDB
import Darwin
@testable import SharedCore

final class OCRProcessTests: XCTestCase {
    private struct Fixture: Sendable {
        let root: URL
        var helper: URL { root.appendingPathComponent("worker.sh") }
        var pid: URL { root.appendingPathComponent("worker.pid") }
        var input: URL { root.appendingPathComponent("input-path.txt") }
        var image: URL { root.appendingPathComponent("image.png") }
    }

    private func fixture(script: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-process-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = Fixture(root: root)
        try ("#!/bin/sh\nprintf '%s' \"$$\" > '" + fixture.pid.path + "'\n" +
             "printf '%s' \"$1\" > '" + fixture.input.path + "'\n" + script + "\n")
            .write(to: fixture.helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.helper.path)
        let bitmap = CGContext(data: nil, width: 519, height: 196, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 519, height: 196))
        let destination = CGImageDestinationCreateWithURL(fixture.image as CFURL,
            UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, bitmap.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return fixture
    }

    private func assertStoppedAndCleaned(_ fixture: Fixture, file: StaticString = #filePath,
                                         line: UInt = #line) throws {
        let pid = try XCTUnwrap(pid_t(String(contentsOf: fixture.pid, encoding: .utf8)),
                                file: file, line: line)
        XCTAssertEqual(kill(pid, 0), -1, "OCR child must be gone", file: file, line: line)
        XCTAssertEqual(errno, ESRCH, file: file, line: line)
        let input = try String(contentsOf: fixture.input, encoding: .utf8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: input), "Snapshot must be removed",
                       file: file, line: line)
    }

    func testHardTimeoutKillsAnUncooperativeChildAndAllowsNextOCR() throws {
        let hanging = try fixture(script: "trap '' TERM\nexec /bin/sleep 60")
        let began = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try ImageOCRExtractor(ocr: OCRService(helperURL: hanging.helper))
            .extract(fileURL: hanging.image, context: .init(ocrTimeout: 0.25))) {
                XCTAssertEqual($0 as? ExtractionError, .ocrTimedOut)
            }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 2)
        try assertStoppedAndCleaned(hanging)

        let healthy = try fixture(script: "printf '%s' '[\"Weiter\"]' > \"$2\"")
        let result = try ImageOCRExtractor(ocr: OCRService(helperURL: healthy.helper))
            .extract(fileURL: healthy.image, context: .init())
        XCTAssertEqual(result.segments.first?.text, "Weiter")
        try assertStoppedAndCleaned(healthy)
    }

    func testCancellationKillsChildWithoutWaitingForTimeout() async throws {
        let fixture = try fixture(script: "trap '' TERM\nexec /bin/sleep 60")
        let worker = Task.detached {
            try ImageOCRExtractor(ocr: OCRService(helperURL: fixture.helper))
                .extract(fileURL: fixture.image, context: .init(ocrTimeout: 30, checkpoint: {}))
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: fixture.pid.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.pid.path))
        let began = ProcessInfo.processInfo.systemUptime
        worker.cancel()
        do { _ = try await worker.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 2)
        try assertStoppedAndCleaned(fixture)
    }

    func testCrashAndInvalidResponseAreFailuresRatherThanEmptySuccess() throws {
        for script in ["exit 1", "printf '%s' 'invalid JSON' > \"$2\""] {
            let fixture = try fixture(script: script)
            XCTAssertThrowsError(try ImageOCRExtractor(ocr: OCRService(helperURL: fixture.helper))
                .extract(fileURL: fixture.image, context: .init())) {
                    XCTAssertEqual($0 as? ExtractionError, .ocrFailed)
                }
            try assertStoppedAndCleaned(fixture)
        }
    }

    func testMissingHelperReportsAnError() throws {
        let fixture = try fixture(script: "exit 0")
        XCTAssertThrowsError(try ImageOCRExtractor(ocr: OCRService(helperURL: fixture.root.appendingPathComponent("missing")))
            .extract(fileURL: fixture.image, context: .init())) {
                XCTAssertEqual($0 as? ExtractionError, .ocrUnavailable)
            }
    }

    func testRepeatedRasterUsesCacheAndLanguageChangeInvalidatesIt() throws {
        let fixture = try fixture(script: "printf '%s' '[\"Cached result\"]' > \"$2\"")
        let db = try IndexDatabase(url: fixture.root.appendingPathComponent("cache/index.sqlite"))
        defer { try? db.dbPool.close() }
        try db.upsertSource(.init(id: "s", path: fixture.root.path))
        try db.upsertFile(.init(sourceId: "s", relativePath: "image.png", filename: "image.png",
                               fileExtension: "png", size: 1, mtime: nil))
        let id = try XCTUnwrap(try db.searchFilenames("image.png").first?.id)
        let cache = DatabaseOCRCache(db: db, fileId: id)
        let context = ExtractionContext(ocrCache: cache)
        let service = OCRService(helperURL: fixture.helper)
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(fixture.image as CFURL, nil)!, 0, nil)!
        XCTAssertEqual(try service.recognizeLines(in: image, context: context), ["Cached result"])
        try FileManager.default.removeItem(at: fixture.helper)
        XCTAssertEqual(try service.recognizeLines(in: image, context: context), ["Cached result"])
        XCTAssertThrowsError(try service.recognizeLines(in: image, languages: ["en-US"], context: context)) {
            XCTAssertEqual($0 as? ExtractionError, .ocrUnavailable)
        }
    }

    func testScannedPDFUsesTheSameHardTimeout() throws {
        let fixture = try fixture(script: "trap '' TERM\nexec /bin/sleep 60")
        let pdf = fixture.root.appendingPathComponent("scan.pdf")
        var box = CGRect(x: 0, y: 0, width: 519, height: 196)
        let context = CGContext(pdf as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(box)
        context.endPDFPage()
        context.closePDF()
        XCTAssertThrowsError(try PDFExtractor(ocr: OCRService(helperURL: fixture.helper))
            .extract(fileURL: pdf, context: .init(ocrTimeout: 0.25))) {
                XCTAssertEqual($0 as? ExtractionError, .ocrTimedOut)
            }
        try assertStoppedAndCleaned(fixture)
    }

    func testSchedulerContinuesOtherFilesAndSourcesAndPreservesCachedOCR() async throws {
        let fixture = try fixture(script: "trap '' TERM\nexec /bin/sleep 60")
        let db = try IndexDatabase(url: fixture.root.appendingPathComponent("db/index.sqlite"))
        let first = SourceRecord(id: "first", path: fixture.root.path)
        let secondRoot = fixture.root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        let second = SourceRecord(id: "second", path: secondRoot.path)
        try db.upsertSource(first); try db.upsertSource(second)
        let text = fixture.root.appendingPathComponent("next.txt")
        let other = secondRoot.appendingPathComponent("other.txt")
        try Data("Following document".utf8).write(to: text)
        try Data("Second source".utf8).write(to: other)
        for (url, source) in [(fixture.image, first), (text, first), (other, second)] {
            let metadata = try LocalFileMetadataProvider().metadata(for: url)
            try db.upsertFile(FileRecord(sourceId: source.id, relativePath: url.lastPathComponent,
                filename: url.lastPathComponent, fileExtension: url.pathExtension,
                size: metadata.size, mtime: metadata.modificationDate))
        }
        let imageID = try XCTUnwrap(try db.searchFilenames("image.png").first?.id)
        try db.storeContent(fileId: imageID,
            chunks: [ChunkRecord(fileId: imageID, ordinal: 0, text: "Cached OCR")],
            mtime: Date(timeIntervalSince1970: 0), version: "old")
        let content = ContentIndexer(registry: ExtractorRegistry(extractors: [
            ImageOCRExtractor(ocr: OCRService(helperURL: fixture.helper)), PlainTextExtractor(),
        ]), context: .init(ocrTimeout: 0.25))
        let worker = IndexWorker(db: db, content: content)
        let scheduler = IndexScheduler(db: db, control: IndexControl(environment: { .init() })) {
            job, checkpoint in try await worker.perform(job, checkpoint: checkpoint)
        }
        addTeardownBlock { await scheduler.stop(); try db.dbPool.close() }
        try await scheduler.enqueue([.init(sourceId: first.id, kind: .content),
                                     .init(sourceId: second.id, kind: .content)])
        try await scheduler.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try db.searchChunks("Second").isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await scheduler.stop()
        XCTAssertEqual(try db.searchChunks("Following").count, 1)
        XCTAssertEqual(try db.searchChunks("Second").count, 1)
        XCTAssertEqual(try db.searchChunks("Cached").count, 1, "Keep the last successful OCR")
        let failure = try await db.dbPool.read {
            try String.fetchOne($0, sql: "SELECT errorCode FROM file_failures WHERE fileId = ?",
                                arguments: [imageID])
        }
        XCTAssertEqual(failure, "ocrTimeout")
        try assertStoppedAndCleaned(fixture)
    }
}
