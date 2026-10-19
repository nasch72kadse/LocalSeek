import Foundation

/// Typisierter Suchausdruck. Trennt freien Volltext (Tokens/Phrasen) von
/// strukturierten Filtern. Bewusst DB-neutral: die Übersetzung nach FTS5/SQL
/// erfolgt erst in `IndexDatabase`, damit nie ungeprüfter Nutzertext in einen
/// FTS5-/SQL-Ausdruck gelangt (SPEC §7 „Suchsyntax").
public struct ParsedQuery: Sendable, Equatable {
    public init() {}
    /// Freie Tokens — alle müssen vorkommen (AND).
    public var terms: [String] = []
    /// Exakte Phrasen aus `"…"`.
    public var phrases: [String] = []
    /// `ext:`/`type:` — Dateiendungen (lowercase, ohne Punkt).
    public var extensions: Set<String> = []
    /// `path:` — Teilstrings, auf die der relative Pfad passen muss.
    public var pathContains: [String] = []
    /// `after:yyyy-MM-dd` — nur Dateien mit `mtime >=` diesem Tagesbeginn.
    public var after: Date?
    /// `before:yyyy-MM-dd` — nur Dateien mit `mtime <` diesem Tagesbeginn.
    public var before: Date?
    public var sourceContains: [String] = []
    public var minimumBytes: Int64?
    public var maximumBytes: Int64?
    public var favoritesOnly = false
    public var searchText: String { (terms + phrases).joined(separator: " ") }
    public var hasFilters: Bool {
        !extensions.isEmpty || !pathContains.isEmpty || after != nil || before != nil
        || !sourceContains.isEmpty || minimumBytes != nil || maximumBytes != nil || favoritesOnly
    }

    /// Enthält der Ausdruck überhaupt Volltext (sonst ist eine Inhaltssuche sinnlos)?
    public var hasTextMatch: Bool { !terms.isEmpty || !phrases.isEmpty }
}

/// Zerlegt eine rohe Sucheingabe in einen `ParsedQuery`. Unterstützt exakte
/// Phrasen in Anführungszeichen und die Filter `ext:`/`type:`/`path:`/`after:`/`before:`;
/// alles Übrige sind freie Tokens.
public enum QueryParser {
    private static let filterKeys: Set<String> = ["ext", "type", "path", "after", "before", "source", "minsize", "maxsize", "favorite"]

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        f.isLenient = false
        return f
    }()

    public static func parse(_ raw: String) -> ParsedQuery {
        var result = ParsedQuery()

        for token in tokenize(raw) {
            switch token {
            case .phrase(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.phrases.append(trimmed) }

            case .word(let text):
                if let colon = text.firstIndex(of: ":"),
                   case let key = text[text.startIndex..<colon].lowercased(),
                   filterKeys.contains(key) {
                    let value = String(text[text.index(after: colon)...])
                    apply(key: key, value: value, to: &result)
                } else {
                    result.terms.append(text)
                }
            }
        }
        return result
    }

    private static func apply(key: String, value: String, to query: inout ParsedQuery) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        switch key {
        case "ext", "type":
            query.extensions.insert(value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))
        case "path":
            query.pathContains.append(value)
        case "after":
            if let date = dateFormatter.date(from: value), dateFormatter.string(from: date) == value { query.after = date }
        case "before":
            if let date = dateFormatter.date(from: value), dateFormatter.string(from: date) == value { query.before = date }
        case "source": query.sourceContains.append(value)
        case "minsize": query.minimumBytes = bytes(value)
        case "maxsize": query.maximumBytes = bytes(value)
        case "favorite": query.favoritesOnly = ["true", "1", "yes"].contains(value.lowercased())
        default:
            break
        }
    }

    private static func bytes(_ raw: String) -> Int64? {
        let value = raw.uppercased()
        let units: [(String, Double)] = [("GIB", 1_073_741_824), ("MIB", 1_048_576), ("KIB", 1024),
                                          ("GB", 1_000_000_000), ("MB", 1_000_000), ("KB", 1000), ("B", 1)]
        for (suffix, multiplier) in units where value.hasSuffix(suffix) {
            guard let number = Double(value.dropLast(suffix.count)), number >= 0,
                  number * multiplier < Double(Int64.max) else { return nil }
            return Int64(number * multiplier)
        }
        guard let result = Int64(value), result >= 0 else { return nil }
        return result
    }

    // MARK: - Tokenisierung

    private enum Token {
        case word(String)     // zusammenhängendes Nicht-Whitespace, evtl. `key:value`
        case phrase(String)   // Inhalt zwischen `"…"`
    }

    /// Zerlegt an Whitespace, respektiert `"…"`-Phrasen. `key:"wert mit leer"` wird
    /// zu einem Word-Token `key:wert mit leer` zusammengeführt (Phrase direkt nach `:`).
    private static func tokenize(_ raw: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""        // laufendes Word-Token
        var phrase = ""         // Inhalt der offenen Phrase
        var inQuotes = false

        func flushWord() {
            if !current.isEmpty { tokens.append(.word(current)); current = "" }
        }

        for char in raw {
            if char == "\"" {
                if inQuotes {
                    if current.hasSuffix(":") {   // Phrase hängt an `key:` → Word
                        current += phrase
                        flushWord()
                    } else {
                        flushWord()
                        tokens.append(.phrase(phrase))
                    }
                    phrase = ""
                    inQuotes = false
                } else {
                    inQuotes = true
                }
            } else if inQuotes {
                phrase.append(char)
            } else if char.isWhitespace {
                flushWord()
            } else {
                current.append(char)
            }
        }

        if inQuotes {   // unbalanciertes Anführungszeichen: Rest retten
            if current.hasSuffix(":") {
                current += phrase
                flushWord()
            } else {
                flushWord()
                if !phrase.isEmpty { tokens.append(.phrase(phrase)) }
            }
        } else {
            flushWord()
        }
        return tokens
    }
}
