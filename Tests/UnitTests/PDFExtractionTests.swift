import XCTest
import AppKit
@testable import SharedCore

/// Verifiziert die seitenweise PDF-Textextraktion (PDFKit) inkl. Seiten-Fundstelle.
/// Das Test-PDF wird mit echter Textebene via Core Graphics erzeugt.
final class PDFExtractionTests: XCTestCase {

    private func makePDF(_ pages: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("localseek-pdf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("doc.pdf")

        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 300)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw ExtractionError.unreadable
        }
        for text in pages {
            ctx.beginPDFPage(nil)
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            (text as NSString).draw(at: NSPoint(x: 20, y: 150),
                withAttributes: [.font: NSFont.systemFont(ofSize: 18)])
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    func testPDFExtractsPerPageSegments() async throws {
        let url = try makePDF(["Vertraulicher Pruefbericht", "Zweite Seite Inhalt"])
        let doc = try await PDFExtractor().extract(fileURL: url, context: ExtractionContext())

        XCTAssertEqual(doc.segments.count, 2)
        XCTAssertEqual(doc.segments[0].location, .page(1))
        XCTAssertEqual(doc.segments[1].location, .page(2))
        XCTAssertTrue(doc.segments[0].text.contains("Pruefbericht"), doc.segments[0].text)
        XCTAssertTrue(doc.segments[1].text.contains("Zweite"), doc.segments[1].text)
        XCTAssertEqual(doc.segments[0].kind, .body)
    }

    func testPDFWordOnPageEight() throws {
        let url = try makePDF((1...8).map { $0 == 8 ? "UniquePaymentRisk" : "Page \($0)" })
        let result = try PDFExtractor().extract(fileURL: url, context: .init())
        XCTAssertEqual(result.segments.first { $0.text.contains("UniquePaymentRisk") }?.location, .page(8))
    }

    func testPDFSkipsEmptyPages() async throws {
        // Wirklich leere Seite (kein Text, keine Grafik) → OCR findet nichts → kein Segment.
        let url = try makePDF(["Nur diese Seite hat Text", ""])
        let doc = try await PDFExtractor().extract(fileURL: url, context: ExtractionContext())
        XCTAssertEqual(doc.segments.count, 1)
        XCTAssertEqual(doc.segments[0].location, .page(1))
    }

    func testPDFUnreadableThrows() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).pdf")
        try Data([0x25, 0x21, 0x00]).write(to: url) // kein gültiges PDF
        do {
            _ = try await PDFExtractor().extract(fileURL: url, context: ExtractionContext())
            XCTFail("Erwarte ExtractionError.unreadable")
        } catch ExtractionError.unreadable {
            // erwartet
        }
    }
}
