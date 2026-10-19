import Foundation
import AppKit

/// Offline text extraction. No WebKit, URL loading or HTML document importer.
public struct HTMLExtractor: DocumentExtractor {
    public init() {}
    public let supportedExtensions: Set<String> = ["html", "htm"]
    public func extract(fileURL: URL, context: ExtractionContext) throws -> ExtractedDocument {
        let text = Self.text(from: try readText(fileURL: fileURL, context: context))
        return ExtractedDocument(segments: text.isEmpty ? [] : [DocumentSegment(text: text)])
    }
    public static func text(from html: String) -> String {
        var result = "", cursor = html.startIndex
        let breaks: Set<String> = ["p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "section", "article", "hr"]
        let hidden: Set<String> = ["script", "style", "head", "template"]
        while cursor < html.endIndex {
            guard html[cursor] == "<" else { result.append(html[cursor]); cursor = html.index(after: cursor); continue }
            if html[cursor...].hasPrefix("<!--") {
                guard let end = html.range(of: "-->", range: cursor..<html.endIndex) else { break }
                cursor = end.upperBound; continue
            }
            let start = html.index(after: cursor)
            guard start < html.endIndex else { result.append("<"); break }
            if !html[start].isLetter && html[start] != "/" && html[start] != "!" {
                result.append("<"); cursor = start; continue
            }
            var end = start, quote: Character?, tag = ""
            var tagBytes = 0
            while end < html.endIndex {
                let ch = html[end]
                if let active = quote { if ch == active { quote = nil } }
                else if ch == "\"" || ch == "'" { quote = ch }
                else if ch == ">" { break }
                let width = ch.utf8.count
                if width <= 8192 - tagBytes { tag.append(ch); tagBytes += width }
                end = html.index(after: end)
            }
            guard end < html.endIndex else { break }
            cursor = html.index(after: end)
            let raw = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let closing = raw.hasPrefix("/")
            let name = String(raw.drop(while: { $0 == "/" }).prefix { $0.isLetter || $0.isNumber })
            if !closing && hidden.contains(name) {
                // Raw script/style text may contain '<' and '>' operators. Skip to
                // its actual closing tag instead of interpreting script as markup.
                var search = cursor
                var closingStart: String.Index?
                while let close = html.range(of: "</" + name, options: .caseInsensitive, range: search..<html.endIndex) {
                    if close.upperBound == html.endIndex || html[close.upperBound].isWhitespace || html[close.upperBound] == ">" {
                        closingStart = close.lowerBound; break
                    }
                    search = close.upperBound
                }
                guard let closingStart else { break }
                cursor = closingStart
            } else if breaks.contains(name) { result.append("\n") }
        }
        result = decodeEntities(result)

        return result.components(separatedBy: .newlines).map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
    private static func decodeEntities(_ text: String) -> String {
        let entities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "auml": "ä", "ouml": "ö", "uuml": "ü", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß", "ndash": "–", "mdash": "—", "copy": "©"]
        var result = "", cursor = text.startIndex
        while cursor < text.endIndex {
            if text[cursor] == "&" {
                let start = text.index(after: cursor)
                let end = text.index(start, offsetBy: 14, limitedBy: text.endIndex) ?? text.endIndex
                if let semicolon = text[start..<end].firstIndex(of: ";") {
                    let key = String(text[start..<semicolon]); var value = entities[key]
                    if key.hasPrefix("#") {
                        let number = key.hasPrefix("#x") || key.hasPrefix("#X") ? UInt32(key.dropFirst(2), radix: 16) : UInt32(key.dropFirst())
                        if let number, let scalar = UnicodeScalar(number) { value = String(scalar) }
                    }
                    if let value { result += value; cursor = text.index(after: semicolon); continue }
                }
            }
            result.append(text[cursor]); cursor = text.index(after: cursor)
        }
        return result
    }

}

public struct RTFExtractor: DocumentExtractor {
    public init() {}
    public let supportedExtensions: Set<String> = ["rtf"]
    public func extract(fileURL: URL, context: ExtractionContext) throws -> ExtractedDocument {
        let data = try boundedData(fileURL: fileURL, maxBytes: context.maxBytes)
        guard let text = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string else { throw ExtractionError.cannotDecodeText }
        return ExtractedDocument(segments: text.isEmpty ? [] : [DocumentSegment(text: text)])
    }
}

/// Common MIME email: folded headers, multipart alternatives/mixed, base64,
/// quoted-printable and common charsets. Attachments are excluded, never followed.
public struct EMLExtractor: DocumentExtractor {
    public init() {}
    public let supportedExtensions: Set<String> = ["eml"]
    public func extract(fileURL: URL, context: ExtractionContext) throws -> ExtractedDocument {
        let data = try boundedData(fileURL: fileURL, maxBytes: context.maxBytes)
        let raw = String(data: data, encoding: .isoLatin1) ?? ""
        var parts = 0, remaining = min(context.maxBytes, 50 * 1024 * 1024) * 4
        let (headers, _) = split(raw)
        let body = try parse(raw, depth: 0, parts: &parts, remaining: &remaining)
        let subject = decodedHeader(headers["subject"] ?? "")
        var segments: [DocumentSegment] = []
        if !subject.isEmpty { segments.append(DocumentSegment(text: subject, location: .section("Betreff"), kind: .heading)) }
        if !body.isEmpty { segments.append(DocumentSegment(text: body, location: .section("Nachricht"))) }
        return ExtractedDocument(title: subject.isEmpty ? nil : subject, segments: segments)
    }
    private func split(_ raw: String) -> ([String: String], String) {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard let separator = normalized.range(of: "\n\n") else { return ([:], normalized) }
        var headers: [String: String] = [:]; var key = ""
        for line in normalized[..<separator.lowerBound].split(separator: "\n", omittingEmptySubsequences: false) {
            if line.first?.isWhitespace == true { headers[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces) }
            else if let colon = line.firstIndex(of: ":") { key = line[..<colon].lowercased(); headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) }
        }
        return (headers, String(normalized[separator.upperBound...]))
    }
    private func parameter(_ key: String, in header: String) -> String? {
        for part in header.split(separator: ";").dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 && pair[0].lowercased() == key { return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return nil
    }
    private func parse(_ raw: String, depth: Int, parts: inout Int, remaining: inout Int) throws -> String {
        try Task.checkCancellation(); parts += 1
        remaining -= raw.unicodeScalars.count
        guard remaining >= 0 else { throw ExtractionError.resourceLimit }
        guard depth <= 12, parts <= 200 else { throw ExtractionError.resourceLimit }
        let (headers, body) = split(raw)
        if headers["content-disposition"]?.lowercased().hasPrefix("attachment") == true { return "" }
        let contentType = headers["content-type"] ?? "text/plain; charset=us-ascii"
        let type = contentType.split(separator: ";").first?.lowercased().trimmingCharacters(in: .whitespaces) ?? "text/plain"
        if type.hasPrefix("multipart/") {
            guard let boundary = parameter("boundary", in: contentType), !boundary.isEmpty, boundary.count <= 200 else { throw ExtractionError.unreadable }
            var blocks: [String] = []; var current: [String]? = nil
            for line in body.components(separatedBy: "\n") {
                let delimiter = line.trimmingCharacters(in: .whitespaces)
                if delimiter == "--" + boundary || delimiter == "--" + boundary + "--" {
                    if let current { blocks.append(current.joined(separator: "\n")); if blocks.count > 200 { throw ExtractionError.resourceLimit } }
                    current = delimiter == "--" + boundary + "--" ? nil : []
                } else if current != nil { current?.append(line) }
            }
            if let current { blocks.append(current.joined(separator: "\n")) }
            if type == "multipart/alternative" {
                if let plain = blocks.first(where: { split($0).0["content-type"]?.lowercased().hasPrefix("text/plain") == true }) { return try parse(plain, depth: depth + 1, parts: &parts, remaining: &remaining) }
                if let last = blocks.last { return try parse(last, depth: depth + 1, parts: &parts, remaining: &remaining) }; return ""
            }
            return try blocks.map { try parse($0, depth: depth + 1, parts: &parts, remaining: &remaining) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        guard type == "text/plain" || type == "text/html" else { return "" }
        let data = decode(body, transfer: headers["content-transfer-encoding"] ?? "")
        let text = decodeText(data, charset: parameter("charset", in: contentType) ?? "utf-8")
        return type == "text/html" ? HTMLExtractor.text(from: text) : text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func decode(_ text: String, transfer: String) -> Data {
        if transfer.lowercased().trimmingCharacters(in: .whitespaces) == "base64" { return Data(base64Encoded: text, options: .ignoreUnknownCharacters) ?? Data() }
        let bytes = Array(text.data(using: .isoLatin1) ?? Data(text.utf8))
        guard transfer.lowercased() == "quoted-printable" else { return Data(bytes) }
        var output = Data(); var i = 0
        while i < bytes.count {
            if bytes[i] == 61 {
                if i + 1 < bytes.count, bytes[i + 1] == 10 { i += 2; continue }
                if i + 2 < bytes.count, let value = UInt8(String(bytes: bytes[(i + 1)...(i + 2)], encoding: .ascii) ?? "", radix: 16) { output.append(value); i += 3; continue }
            }
            output.append(bytes[i]); i += 1
        }
        return output
    }
    private func decodeText(_ data: Data, charset: String) -> String {
        let encoding: String.Encoding = switch charset.lowercased() {
        case "iso-8859-1", "latin1": .isoLatin1
        case "windows-1252": .windowsCP1252
        case "utf-16": .utf16
        default: .utf8
        }
        return String(data: data, encoding: encoding) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }
    private func decodedHeader(_ header: String) -> String {
        let regex = try! NSRegularExpression(pattern: "=\\?([^?]+)\\?([bBqQ])\\?([^?]*)\\?=")
        var result = header; let original = header as NSString
        for match in regex.matches(in: header, range: NSRange(location: 0, length: original.length)).reversed() {
            let charset = original.substring(with: match.range(at: 1)); let encoding = original.substring(with: match.range(at: 2)).lowercased()
            let raw = original.substring(with: match.range(at: 3)).replacingOccurrences(of: "_", with: " ")
            let text = decodeText(decode(raw, transfer: encoding == "b" ? "base64" : "quoted-printable"), charset: charset)
            if let range = Range(match.range, in: result) { result.replaceSubrange(range, with: text) }
        }
        return result
    }
}
