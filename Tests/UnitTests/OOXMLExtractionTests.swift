import XCTest
import ZIPFoundation
@testable import SharedCore

/// Verifiziert die OOXML-Extraktoren (DOCX/PPTX/XLSX). Minimal gültige OOXML-ZIPs
/// werden im Test mit ZIPFoundation erzeugt (nur die vom Extraktor gelesenen Parts).
final class OOXMLExtractionTests: XCTestCase {

    private func makeZip(_ entries: [String: String], ext: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("localseek-ooxml-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("doc.\(ext)")
        let archive = try Archive(url: url, accessMode: .create)
        for (path, content) in entries {
            let data = Data(content.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                                 compressionMethod: .deflate) { position, size in
                let start = Int(position)
                return data.subdata(in: start..<min(start + size, data.count))
            }
        }
        return url
    }

    private let ctx = ExtractionContext()

    func testDOCXParagraphs() async throws {
        let doc = """
        <?xml version="1.0"?>
        <w:document xmlns:w="http://x"><w:body>
        <w:p><w:r><w:t>Erster Absatz Vertraulich</w:t></w:r></w:p>
        <w:p><w:r><w:t xml:space="preserve">Zweiter </w:t></w:r><w:r><w:t>Absatz</w:t></w:r></w:p>
        </w:body></w:document>
        """
        let url = try makeZip(["word/document.xml": doc], ext: "docx")
        let result = try await DOCXExtractor().extract(fileURL: url, context: ctx)

        XCTAssertEqual(result.segments.map(\.text), ["Erster Absatz Vertraulich", "Zweiter Absatz"])
        XCTAssertEqual(result.segments.first?.kind, .body)
    }

    func testPPTXSlidesInOrder() async throws {
        func slide(_ texts: [String]) -> String {
            let ts = texts.map { "<a:t>\($0)</a:t>" }.joined()
            return "<p:sld xmlns:a=\"http://x\"><p:cSld><p:spTree>\(ts)</p:spTree></p:cSld></p:sld>"
        }
        let url = try makeZip([
            "ppt/slides/slide1.xml": slide(["Folie Eins", "Punkt A"]),
            "ppt/slides/slide2.xml": slide(["Folie Zwei"]),
        ], ext: "pptx")
        let result = try await PPTXExtractor().extract(fileURL: url, context: ctx)

        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments[0].location, .slide(1))
        XCTAssertEqual(result.segments[1].location, .slide(2))
        XCTAssertTrue(result.segments[0].text.contains("Folie Eins"))
        XCTAssertTrue(result.segments[0].text.contains("Punkt A"))
        XCTAssertTrue(result.segments[1].text.contains("Folie Zwei"))
    }

    func testXLSXResolvesSharedStringsAndRange() async throws {
        let shared = """
        <sst xmlns="http://x"><si><t>Umsatz</t></si><si><t>Region</t></si></sst>
        """
        let sheet = """
        <worksheet xmlns="http://x"><sheetData>
        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
        <row r="2"><c r="A2"><v>100</v></c><c r="B2" t="inlineStr"><is><t>Nord</t></is></c></row>
        </sheetData></worksheet>
        """
        let url = try makeZip([
            "xl/sharedStrings.xml": shared,
            "xl/worksheets/sheet1.xml": sheet,
        ], ext: "xlsx")
        let result = try await XLSXExtractor().extract(fileURL: url, context: ctx)

        let seg = try XCTUnwrap(result.segments.first)
        XCTAssertEqual(seg.kind, .table)
        XCTAssertEqual(seg.location, .sheet(name: "Sheet1", range: "A1:B1"))
        for token in ["Umsatz", "Region", "100", "Nord"] {
            XCTAssertTrue(result.segments.map(\.text).joined(separator: " ").contains(token), "fehlt: \(token) in \(seg.text)")
        }
    }

    func testPresentationOrderNotesAndSlideSeventeen() throws {
        var parts: [String: String] = [:]
        for i in 1...17 { parts["ppt/slides/slide\(i).xml"] = "<p:sld xmlns:p='p' xmlns:a='a'><a:t>Slide \(i)</a:t></p:sld>" }
        parts["ppt/presentation.xml"] = "<p:presentation xmlns:p='p' xmlns:r='r'>" + (1...17).reversed().map { "<p:sldId r:id='r\($0)'/>" }.joined() + "</p:presentation>"
        parts["ppt/_rels/presentation.xml.rels"] = "<Relationships>" + (1...17).map { "<Relationship Id='r\($0)' Target='slides/slide\($0).xml'/>" }.joined() + "</Relationships>"
        parts["ppt/slides/_rels/slide1.xml.rels"] = "<Relationships><Relationship Id='n' Target='../notesSlides/notesSlide1.xml'/></Relationships>"
        parts["ppt/notesSlides/notesSlide1.xml"] = "<a:notes xmlns:a='a'><a:t>UniquePaymentRisk</a:t></a:notes>"
        let result = try PPTXExtractor().extract(fileURL: makeZip(parts, ext: "pptx"), context: .init())
        XCTAssertEqual(result.segments.first?.text, "Slide 17")
        XCTAssertEqual(result.segments.first { $0.text.contains("UniquePaymentRisk") }?.location, .slide(17))
        XCTAssertEqual(result.segments.last?.kind, .note)
    }
    func testExcelRisksB42AndFormulaCachedResult() throws {
        let parts = ["xl/workbook.xml": "<workbook xmlns:r='r'><sheet name='Risks' r:id='r1'/></workbook>",
                     "xl/_rels/workbook.xml.rels": "<Relationships><Relationship Id='r1' Target='worksheets/sheet1.xml'/></Relationships>",
                     "xl/worksheets/sheet1.xml": "<worksheet><sheetData><row r='42'><c r='B42'><f>SUM(B1:B41)</f><v>12345</v></c></row></sheetData></worksheet>"]
        let result = try XLSXExtractor().extract(fileURL: makeZip(parts, ext: "xlsx"), context: .init())
        XCTAssertEqual(result.segments.first?.location, .sheet(name: "Risks", range: "B42:B42"))
        XCTAssertTrue(result.segments.first?.text.contains("=SUM(B1:B41) 12345") == true)
    }

    func testOOXMLMissingPartReturnsEmpty() async throws {
        let url = try makeZip(["unrelated.xml": "<x/>"], ext: "docx")
        let result = try await DOCXExtractor().extract(fileURL: url, context: ctx)
        XCTAssertTrue(result.segments.isEmpty)
    }
}
