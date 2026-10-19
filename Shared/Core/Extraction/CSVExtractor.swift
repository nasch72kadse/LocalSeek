import Foundation

/// Extraktor für CSV/TSV. Parst RFC-4180-nah (Anführungszeichen, verdoppelte
/// Quotes, eingebettete Zeilenumbrüche/Trenner) und liefert den normalisierten
/// Tabelleninhalt als einen Table-Abschnitt (Zellen leer­zeichen-, Zeilen
/// zeilenumbruchgetrennt). TSV wird an der Endung erkannt (Tab statt Komma).
public struct CSVExtractor: DocumentExtractor {
    public init() {}

    public let supportedExtensions: Set<String> = ["csv", "tsv"]

    public func extract(fileURL: URL, context: ExtractionContext) throws -> ExtractedDocument {
        let raw = try readText(fileURL: fileURL, context: context)
        guard !raw.isEmpty else { return ExtractedDocument(segments: []) }

        let delimiter: Character = fileURL.pathExtension.lowercased() == "tsv" ? "\t" : ","
        let rows = Self.parse(raw, delimiter: delimiter)
        let text = rows.map { $0.joined(separator: " ") }.joined(separator: "\n")
        guard !text.isEmpty else { return ExtractedDocument(segments: []) }

        return ExtractedDocument(segments: [DocumentSegment(text: text, location: .none, kind: .table)])
    }

    /// Zerlegt CSV/TSV-Text in Zeilen × Felder. Quotes mit `""`-Escape; Trenner und
    /// Zeilenumbrüche innerhalb von Quotes bleiben Teil des Feldes.
    static func parse(_ input: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        var iterator = input.makeIterator()
        var pending: Character? = nil

        func nextChar() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }

        func endField() { row.append(field); field = "" }
        func endRow() { endField(); rows.append(row); row = [] }

        while let c = nextChar() {
            if inQuotes {
                if c == "\"" {
                    if let n = nextChar() {
                        if n == "\"" { field.append("\"") }   // verdoppeltes Quote
                        else { inQuotes = false; pending = n }
                    } else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case delimiter: endField()
                case "\r":
                    if let n = nextChar(), n != "\n" { pending = n }
                    endRow()
                case "\n": endRow()
                default: field.append(c)
                }
            }
        }
        // Letztes Feld/Zeile nur übernehmen, wenn Inhalt vorhanden.
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}
