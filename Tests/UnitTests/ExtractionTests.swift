import XCTest
@testable import SharedCore

/// Verifiziert die Extraktor-Architektur (Protokoll + Registry) und die drei
/// Foundation-basierten P0-Extraktoren (PlainText, CSV/TSV, Markdown).
final class ExtractionTests: XCTestCase {

    private func tmpFile(_ name: String, _ contents: String,
                         encoding: String.Encoding = .utf8) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("localseek-extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.data(using: encoding)!.write(to: url)
        return url
    }

    private func tmpFile(_ name: String, data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("localseek-extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private let ctx = ExtractionContext()

    // MARK: - PlainText

    func testPlainTextSingleBodySegment() async throws {
        let url = try tmpFile("notiz.txt", "Hallo Welt\nZweite Zeile")
        let doc = try await PlainTextExtractor().extract(fileURL: url, context: ctx)
        XCTAssertEqual(doc.segments.count, 1)
        let seg = try XCTUnwrap(doc.segments.first)
        XCTAssertEqual(seg.text, "Hallo Welt\nZweite Zeile")
        XCTAssertEqual(seg.kind, .body)
        XCTAssertEqual(seg.location, .none)
    }

    /// Nicht-UTF-8 (ISO-Latin-1) darf nicht zum Fehler führen (Fallback-Dekodierung).
    func testPlainTextEncodingFallback() async throws {
        let url = try tmpFile("latin.txt", data: Data([0x48, 0x61, 0x6C, 0x6C, 0x6F, 0x20, 0xE4])) // "Hallo ä"
        let doc = try await PlainTextExtractor().extract(fileURL: url, context: ctx)
        let text = try XCTUnwrap(doc.segments.first?.text)
        XCTAssertTrue(text.hasPrefix("Hallo "))
    }

    // MARK: - CSV / TSV

    func testCSVQuotedFieldsParsed() async throws {
        let url = try tmpFile("tab.csv", "name,note\n\"Müller, A.\",ok\n")
        let doc = try await CSVExtractor().extract(fileURL: url, context: ctx)
        let seg = try XCTUnwrap(doc.segments.first)
        XCTAssertEqual(seg.kind, .table)
        // Komma im Feld bleibt erhalten (Quote-Parsing), Felder sonst durch Leerzeichen getrennt.
        XCTAssertTrue(seg.text.contains("Müller, A."), seg.text)
        XCTAssertTrue(seg.text.contains("name note"), seg.text)
    }

    func testTSVUsesTabDelimiter() async throws {
        let url = try tmpFile("data.tsv", "a\tb\n1\t2\n")
        let doc = try await CSVExtractor().extract(fileURL: url, context: ctx)
        let text = try XCTUnwrap(doc.segments.first?.text)
        XCTAssertTrue(text.contains("a b"), text)
    }

    // MARK: - Markdown

    func testMarkdownSplitsByHeadings() async throws {
        let md = """
        # Titel

        Einleitungstext.

        ## Abschnitt A

        Inhalt A.
        """
        let url = try tmpFile("doc.md", md)
        let doc = try await MarkdownExtractor().extract(fileURL: url, context: ctx)

        XCTAssertEqual(doc.title, "Titel")
        let headings = doc.segments.filter { $0.kind == .heading }.map(\.text)
        XCTAssertEqual(headings, ["Titel", "Abschnitt A"])

        let bodyA = doc.segments.first { $0.text == "Inhalt A." }
        XCTAssertEqual(bodyA?.location, .section("Abschnitt A"))
    }

    // MARK: - Registry

    func testRegistryDispatchByExtension() async throws {
        let registry = ExtractorRegistry.standard
        XCTAssertTrue(registry.extractor(for: "md") is MarkdownExtractor)
        XCTAssertTrue(registry.extractor(for: "CSV") is CSVExtractor) // case-insensitiv
        XCTAssertTrue(registry.extractor(for: "txt") is PlainTextExtractor)
        XCTAssertTrue(registry.extractor(for: "pdf") is PDFExtractor)
        XCTAssertTrue(registry.extractor(for: "docx") is DOCXExtractor)
        XCTAssertTrue(registry.extractor(for: "PPTX") is PPTXExtractor) // case-insensitiv
        XCTAssertTrue(registry.extractor(for: "xlsx") is XLSXExtractor)
        XCTAssertNotNil(registry.extractor(for: "rtf"))
    }

    func testRegistryExtractUnsupportedReturnsNil() async throws {
        let url = try tmpFile("archiv.xyz", "egal")
        let doc = try await ExtractorRegistry.standard.extract(fileURL: url, context: ctx)
        XCTAssertNil(doc)
    }

    func testDocumentLocationMapping() {
        XCTAssertEqual(DocumentLocation.page(3).locationType, "page")
        XCTAssertEqual(DocumentLocation.page(3).locationValue, "3")
        XCTAssertEqual(DocumentLocation.sheet(name: "Tabelle1", range: "A1:C10").locationValue, "Tabelle1!A1:C10")
        XCTAssertEqual(DocumentLocation.none.locationType, "none")
    }
}
