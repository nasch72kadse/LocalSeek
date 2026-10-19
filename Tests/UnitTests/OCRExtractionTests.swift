import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import SharedCore

/// Verifiziert die Vision-OCR-Extraktion: Rasterbild → Text (ImageOCRExtractor)
/// und Scan-PDF ohne Textebene → OCR-Fallback im PDFExtractor.
final class OCRExtractionTests: XCTestCase {

    /// Rendert ein Wort als schwarze Schrift auf weißem Grund (gut OCR-bar).
    private func renderWord(_ word: String, size: CGSize = CGSize(width: 600, height: 160)) -> CGImage {
        let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))

        let ns = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        (word as NSString).draw(at: NSPoint(x: 30, y: 50),
            withAttributes: [.font: NSFont.boldSystemFont(ofSize: 72),
                             .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    private func writePNG(_ image: CGImage) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("localseek-ocr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("scan.png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ExtractionError.unreadable }
        return url
    }

    func testImageOCRReadsRenderedText() async throws {
        let url = try writePNG(renderWord("Rechnung"))
        let doc = try await ImageOCRExtractor().extract(fileURL: url, context: ExtractionContext())

        XCTAssertEqual(doc.segments.count, 1, "Erwarte genau ein Body-Segment")
        XCTAssertEqual(doc.segments.first?.kind, .body)
        XCTAssertTrue(doc.segments.first?.text.contains("Rechnung") == true,
                      doc.segments.first?.text ?? "<leer>")
    }

    func testRegistryMapsImageExtensionToOCR() {
        let registry = ExtractorRegistry.standard
        XCTAssertTrue(registry.extractor(for: "png") is ImageOCRExtractor)
        XCTAssertTrue(registry.extractor(for: "JPEG") is ImageOCRExtractor) // case-insensitiv
    }

    /// Scan-PDF: die Seite enthält NUR ein Rasterbild (keine Textebene).
    func testScannedPDFPageIsOCRed() async throws {
        let image = renderWord("Pruefbericht")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("localseek-ocrpdf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("scan.pdf")

        var mediaBox = CGRect(x: 0, y: 0, width: 600, height: 160)
        let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil)!
        ctx.beginPDFPage(nil)
        ctx.draw(image, in: mediaBox)
        ctx.endPDFPage()
        ctx.closePDF()

        let doc = try await PDFExtractor().extract(fileURL: url, context: ExtractionContext())
        XCTAssertEqual(doc.segments.count, 1)
        XCTAssertEqual(doc.segments.first?.location, .page(1))
        XCTAssertTrue(doc.segments.first?.text.contains("Pruefbericht") == true,
                      doc.segments.first?.text ?? "<leer>")
    }
}
