import Foundation
import ZIPFoundation

// MARK: - Gemeinsame OOXML-Helfer

/// Öffnet das OOXML-Archiv lesend; wirft `.unreadable`, wenn es kein gültiges ZIP ist.
private func openArchive(_ fileURL: URL, context: ExtractionContext) throws -> Archive {
    let archive: Archive
    do { archive = try Archive(url: fileURL, accessMode: .read) }
    catch { throw ExtractionError.unreadable }
    var total: UInt64 = 0, count = 0
    for entry in archive {
        count += 1; total += entry.uncompressedSize
        guard count <= 20_000, total <= UInt64(max(0, context.maxBytes)), entry.uncompressedSize <= 16 * 1024 * 1024 else { throw ExtractionError.resourceLimit }
    }
    return archive
}

/// Liest einen einzelnen Part (ZIP-Eintrag) vollständig in Daten; `nil`, wenn er fehlt.
private func readPart(_ archive: Archive, _ path: String) throws -> Data? {
    try Task.checkCancellation()
    guard let entry = archive[path] else { return nil }
    guard entry.uncompressedSize <= 16 * 1024 * 1024 else { throw ExtractionError.resourceLimit }
    var data = Data()
    let crc = try archive.extract(entry, bufferSize: 64 * 1024) { block in
        guard data.count + block.count <= 16 * 1024 * 1024 else { throw ExtractionError.resourceLimit }
        try Task.checkCancellation(); data.append(block)
    }
    guard crc == entry.checksum else { throw ExtractionError.unreadable }
    return data
}

private func parseXML(_ data: Data, with delegate: XMLParserDelegate) throws {
    // Decode declarations too, including UTF-16, before allowing Foundation's parser.
    let upper = String(decoding: data.filter { $0 != 0 }, as: UTF8.self).uppercased()
    guard !upper.contains("<!DOCTYPE"), !upper.contains("<!ENTITY") else { throw ExtractionError.unreadable }
    let parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = false; parser.shouldResolveExternalEntities = false
    parser.externalEntityResolvingPolicy = .never
    let bounded = BoundedXMLDelegate(base: delegate)
    parser.delegate = bounded
    guard parser.parse() else { throw ExtractionError.unreadable }
}

private final class BoundedXMLDelegate: NSObject, XMLParserDelegate {
    let base: XMLParserDelegate
    private var depth = 0, nodes = 0
    init(base: XMLParserDelegate) { self.base = base }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        depth += 1; nodes += 1
        guard depth <= 128, nodes <= 500_000, !Task.isCancelled else { parser.abortParsing(); return }
        base.parser?(parser, didStartElement: name, namespaceURI: namespaceURI, qualifiedName: qualifiedName, attributes: attributes)
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        base.parser?(parser, didEndElement: name, namespaceURI: namespaceURI, qualifiedName: qualifiedName); depth -= 1
    }
    func parser(_ parser: XMLParser, foundCharacters text: String) { base.parser?(parser, foundCharacters: text) }
}

private func relationshipTarget(_ target: String, base: String) -> String? {
    guard !target.contains(":") else { return nil }
    let raw = target.hasPrefix("/") ? String(target.dropFirst()) : base + "/" + target
    var components: [String] = []
    for component in raw.split(separator: "/") {
        if component == ".." { guard !components.isEmpty else { return nil }; components.removeLast() }
        else if component != "." { components.append(String(component)) }
    }
    return components.joined(separator: "/")
}
private final class OOXMLRelationships: NSObject, XMLParserDelegate {
    var targets: [String: String] = [:]
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attrs: [String: String]) {
        if elementName == "Relationship", attrs["TargetMode"] != "External", let id = attrs["Id"], let target = attrs["Target"] { targets[id] = target }
    }
}
private final class SlideOrder: NSObject, XMLParserDelegate {
    var ids: [String] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attrs: [String: String]) {
        if elementName == "p:sldId", let id = attrs["r:id"] { ids.append(id) }
    }
}

/// Numerisches Suffix eines Part-Namens (z. B. `slide12.xml` → 12) für stabile Reihenfolge.
private func trailingNumber(in name: String) -> Int {
    let stem = (name as NSString).deletingPathExtension
    let digits = stem.reversed().prefix { $0.isNumber }.reversed()
    return Int(String(digits)) ?? 0
}

// MARK: - DOCX

/// Extraktor für DOCX. Liest `word/document.xml` und bildet jeden `<w:p>`-Absatz
/// (konkateniert aus seinen `<w:t>`-Läufen) auf einen Body-Abschnitt ab.
public struct DOCXExtractor: DocumentExtractor {
    public init() {}
    public let supportedExtensions: Set<String> = ["docx"]

    public func extract(fileURL: URL, context: ExtractionContext) throws -> ExtractedDocument {
        let archive = try openArchive(fileURL, context: context)
        var segments: [DocumentSegment] = []
        let parts = archive.map(\.path).filter { $0 == "word/document.xml" || ($0.hasPrefix("word/") && ($0.hasPrefix("word/header") || $0.hasPrefix("word/footer") || ["word/comments.xml", "word/footnotes.xml", "word/endnotes.xml"].contains($0))) }.filter { $0.hasSuffix(".xml") }
            .sorted { $0 == "word/document.xml" || ($1 != "word/document.xml" && $0 < $1) }
        for path in parts {
            guard let data = try readPart(archive, path) else { continue }
            let kind: SegmentKind = path.contains("header") ? .header : path.contains("footer") ? .footer : path.contains("comments") ? .comment : path.contains("notes") ? .footnote : .body
            let delegate = DOCXParser(defaultKind: kind)
            try parseXML(data, with: delegate)
            segments += delegate.segments
        }
        return ExtractedDocument(segments: segments)
    }

    private final class DOCXParser: NSObject, XMLParserDelegate {
        var segments: [DocumentSegment] = []
        let defaultKind: SegmentKind
        private var tableDepth = 0, heading = false
        private var section = ""
        init(defaultKind: SegmentKind) { self.defaultKind = defaultKind }
        private var current = ""
        private var inText = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            if elementName == "w:tbl" { tableDepth += 1 }
            if elementName == "w:p" { current = ""; heading = false }
            else if elementName == "w:pStyle", let style = attributeDict["w:val"]?.lowercased() { heading = style.hasPrefix("heading") || style.hasPrefix("überschrift") }
            else if elementName == "w:tab" || elementName == "w:br" { current += " " }
            else if elementName == "w:t" { inText = true }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { current += string }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            if elementName == "w:tbl" { tableDepth -= 1 }
            if elementName == "w:t" { inText = false }
            else if elementName == "w:p" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    if heading { section = trimmed }
                    segments.append(DocumentSegment(text: trimmed, location: section.isEmpty ? .none : .section(section), kind: heading ? .heading : (tableDepth > 0 && defaultKind == .body ? .table : defaultKind)))
                }
                current = ""
            }
        }
    }
}

// MARK: - PPTX

/// Extraktor für PPTX. Iteriert `ppt/slides/slideN.xml` in numerischer Reihenfolge
/// und sammelt je Folie alle `<a:t>`-Texte zu einem Body-Abschnitt mit `.slide(n)`.
public struct PPTXExtractor: DocumentExtractor {
    public init() {}
    public let supportedExtensions: Set<String> = ["pptx"]

    public func extract(fileURL: URL, context: ExtractionContext) throws -> ExtractedDocument {
        let archive = try openArchive(fileURL, context: context)
        var slidePaths = archive
            .map(\.path)
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { trailingNumber(in: $0) < trailingNumber(in: $1) }

        if let data = try readPart(archive, "ppt/presentation.xml"), let rels = try readPart(archive, "ppt/_rels/presentation.xml.rels") {
            let order = SlideOrder(); let relationships = OOXMLRelationships()
            try parseXML(data, with: order); try parseXML(rels, with: relationships)
            let ordered = order.ids.compactMap { relationships.targets[$0].flatMap { relationshipTarget($0, base: "ppt") } }
            if !ordered.isEmpty { slidePaths = ordered }
        }

        var segments: [DocumentSegment] = []
        for (index, path) in slidePaths.enumerated() {
            guard let data = try readPart(archive, path) else { continue }
            let delegate = TextRunParser(element: "a:t")
            try parseXML(data, with: delegate)
            let text = delegate.texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { segments.append(DocumentSegment(text: text, location: .slide(index + 1), kind: .body)) }
            let name = (path as NSString).lastPathComponent
            if let rels = try readPart(archive, "ppt/slides/_rels/" + name + ".rels") {
                let relationships = OOXMLRelationships(); try parseXML(rels, with: relationships)
                for target in relationships.targets.values.sorted() where target.contains("notesSlides/") {
                    guard let notePath = relationshipTarget(target, base: "ppt/slides"), let data = try readPart(archive, notePath) else { continue }
                    let notes = TextRunParser(element: "a:t"); try parseXML(data, with: notes)
                    if !notes.texts.isEmpty { segments.append(DocumentSegment(text: notes.texts.joined(separator: " "), location: .slide(index + 1), kind: .note)) }
                }
            }
        }
        return ExtractedDocument(segments: segments)
    }
}

// MARK: - XLSX

/// Extraktor für XLSX. Löst `xl/sharedStrings.xml` auf, liest Blätter in
/// Arbeitsmappen-Reihenfolge und liefert je Blatt einen Table-Abschnitt
/// mit Blattname und belegtem Zellbereich (`.sheet(name:range:)`).
public struct XLSXExtractor: DocumentExtractor {
    public init() {}
    public let supportedExtensions: Set<String> = ["xlsx"]

    public func extract(fileURL: URL, context: ExtractionContext) throws -> ExtractedDocument {
        let archive = try openArchive(fileURL, context: context)

        var sharedStrings: [String] = []
        if let data = try readPart(archive, "xl/sharedStrings.xml") {
            let delegate = SharedStringsParser()
            try parseXML(data, with: delegate)
            sharedStrings = delegate.strings
        }

        var segments: [DocumentSegment] = []
        for (name, path) in try sheetOrder(archive) {
            guard let data = try readPart(archive, path) else { continue }
            let delegate = WorksheetParser(sharedStrings: sharedStrings)
            try parseXML(data, with: delegate)
            for row in delegate.rows {
                segments.append(DocumentSegment(text: row.text, location: .sheet(name: name, range: row.range), kind: .table))
            }
        }
        return ExtractedDocument(segments: segments)
    }

    /// Liefert Blätter als (Name, Part-Pfad) in Arbeitsmappen-Reihenfolge.
    /// Nutzt `workbook.xml` + `.rels` für echte Namen; fällt sonst auf
    /// `Sheet{N}` aus dem Dateinamen zurück.
    private func sheetOrder(_ archive: Archive) throws -> [(name: String, path: String)] {
        if let wb = try readPart(archive, "xl/workbook.xml"),
           let rels = try readPart(archive, "xl/_rels/workbook.xml.rels") {
            let wbParser = WorkbookParser()
            try parseXML(wb, with: wbParser)
            let relsParser = RelationshipsParser()
            try parseXML(rels, with: relsParser)
            let mapped = wbParser.sheets.compactMap { sheet -> (name: String, path: String)? in
                guard let target = relsParser.targets[sheet.rid] else { return nil }
                guard let path = relationshipTarget(target, base: "xl") else { return nil }
                return (sheet.name, path)
            }
            if !mapped.isEmpty { return mapped }
        }
        // Fallback: Blätter direkt aus dem Archiv, nach Nummer sortiert.
        return archive
            .map(\.path)
            .filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
            .sorted { trailingNumber(in: $0) < trailingNumber(in: $1) }
            .map { (name: "Sheet\(trailingNumber(in: $0))", path: $0) }
    }

    /// Rel-Target (relativ zu `xl/`) auf vollen Part-Pfad bringen.
    private func normalizeTarget(_ target: String) -> String {
        target.hasPrefix("/") ? String(target.dropFirst()) : "xl/\(target)"
    }

    private final class SharedStringsParser: NSObject, XMLParserDelegate {
        var strings: [String] = []
        private var current = ""
        private var inSI = false
        private var inT = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            if elementName == "si" { inSI = true; current = "" }
            else if elementName == "t" && inSI { inT = true }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inT { current += string }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            if elementName == "t" { inT = false }
            else if elementName == "si" { inSI = false; strings.append(current) }
        }
    }

    private final class WorksheetParser: NSObject, XMLParserDelegate {
        let sharedStrings: [String]
        var tokens: [String] = []
        var rows: [(text: String, range: String?)] = []
        var range: String? { bounds.map { "\(colLetters($0.minCol))\($0.minRow):\(colLetters($0.maxCol))\($0.maxRow)" } }

        private var bounds: (minCol: Int, minRow: Int, maxCol: Int, maxRow: Int)?
        private var cellType: String?
        private var cellRef: String?
        private var inV = false, inIS = false, inT = false, inF = false
        private var formula = ""
        private var vText = "", isText = ""

        init(sharedStrings: [String]) { self.sharedStrings = sharedStrings }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            switch elementName {
            case "row": tokens = []; bounds = nil
            case "f": inF = true; formula = ""
            case "c": formula = ""; cellType = attributeDict["t"]; cellRef = attributeDict["r"]; vText = ""; isText = ""
            case "v": inV = true; vText = ""
            case "is": inIS = true; isText = ""
            case "t": if inIS { inT = true }
            default: break
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inF { formula += string }
            else if inV { vText += string }
            else if inT { isText += string }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            switch elementName {
            case "row":
                if !tokens.isEmpty { rows.append((tokens.joined(separator: " "), range)) }
            case "f": inF = false
            case "v": inV = false
            case "t": inT = false
            case "is": inIS = false
            case "c":
                let value: String
                if cellType == "s", let idx = Int(vText.trimmingCharacters(in: .whitespaces)),
                   idx >= 0, idx < sharedStrings.count {
                    value = sharedStrings[idx]
                } else if cellType == "inlineStr" {
                    value = isText
                } else {
                    value = vText
                }
                let trimmed = (formula.isEmpty ? value : "=\(formula) \(value)").trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    tokens.append(trimmed)
                    if let ref = cellRef, let (col, row) = parseRef(ref) { expand(col: col, row: row) }
                }
            default: break
            }
        }

        private func expand(col: Int, row: Int) {
            if var b = bounds {
                b.minCol = min(b.minCol, col); b.minRow = min(b.minRow, row)
                b.maxCol = max(b.maxCol, col); b.maxRow = max(b.maxRow, row)
                bounds = b
            } else {
                bounds = (col, row, col, row)
            }
        }

        private func parseRef(_ ref: String) -> (col: Int, row: Int)? {
            let letters = ref.prefix { $0.isLetter }
            let digits = ref.dropFirst(letters.count)
            guard !letters.isEmpty, let row = Int(digits) else { return nil }
            var col = 0
            guard letters.count <= 3, row > 0, row <= 1_048_576 else { return nil }
            for ch in letters.uppercased() { guard let ascii = ch.asciiValue, ascii >= 65, ascii <= 90 else { return nil }; col = col * 26 + (Int(ascii) - 64) }
            guard col <= 16_384 else { return nil }
            return (col, row)
        }

        private func colLetters(_ index: Int) -> String {
            var n = index, s = ""
            while n > 0 { let r = (n - 1) % 26; s = String(UnicodeScalar(65 + r)!) + s; n = (n - 1) / 26 }
            return s
        }
    }

    private final class WorkbookParser: NSObject, XMLParserDelegate {
        var sheets: [(name: String, rid: String)] = []
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            guard elementName == "sheet" else { return }
            let name = attributeDict["name"] ?? ""
            let rid = attributeDict["r:id"] ?? attributeDict["id"] ?? ""
            if !name.isEmpty, !rid.isEmpty { sheets.append((name, rid)) }
        }
    }

    private final class RelationshipsParser: NSObject, XMLParserDelegate {
        var targets: [String: String] = [:]
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            guard elementName == "Relationship", attributeDict["TargetMode"] != "External", let id = attributeDict["Id"],
                  let target = attributeDict["Target"] else { return }
            targets[id] = target
        }
    }
}

// MARK: - Gemeinsamer Text-Lauf-Parser (PPTX)

/// Sammelt den Textinhalt eines wiederkehrenden Elements (z. B. `a:t`).
private final class TextRunParser: NSObject, XMLParserDelegate {
    let element: String
    var texts: [String] = []
    private var current = ""
    private var inElement = false

    init(element: String) { self.element = element }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == element { inElement = true; current = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inElement { current += string }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if elementName == element {
            inElement = false
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { texts.append(trimmed) }
            current = ""
        }
    }
}
