import Foundation
import GRDB

struct PDFProgress: Sendable {
    let nextPage: Int
    let bytes: Int
    let ocrKeys: Set<String>
}

extension IndexDatabase {
    func pdfProgress(file: FileRecord, version: String) throws -> PDFProgress? {
        try dbPool.write { db in
            guard let id = file.id else { return nil }
            try db.execute(sql: """
                DELETE FROM pdf_progress WHERE fileId = ? AND
                (mtime IS NOT ? OR size != ? OR identity IS NOT ? OR version != ?)
                """, arguments: [id, file.mtime, file.size, file.fileIdentity, version])
            guard let row = try Row.fetchOne(db, sql: "SELECT nextPage, bytes, ocrKeys FROM pdf_progress WHERE fileId = ?", arguments: [id]) else { return nil }
            let keys: String = row["ocrKeys"]
            return PDFProgress(nextPage: row["nextPage"], bytes: row["bytes"],
                ocrKeys: Set(try JSONDecoder().decode([String].self, from: Data(keys.utf8))))
        }
    }

    func savePDFBatch(_ batch: PDFPageBatch, file: FileRecord, version: String, previous: PDFProgress?, keys: Set<String>, maxBytes: Int) throws {
        guard let id = file.id else { throw ExtractionError.changedDuringRead }
        let total = (previous?.bytes ?? 0) + batch.bytes
        guard total <= maxBytes else { throw ExtractionError.resourceLimit }
        let ocrKeys = (previous?.ocrKeys ?? []).union(keys)
        let json = String(decoding: try JSONEncoder().encode(ocrKeys.sorted()), as: UTF8.self)
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO pdf_progress(fileId, mtime, size, identity, version, nextPage, totalPages, bytes, title, ocrKeys)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(fileId) DO UPDATE SET nextPage = excluded.nextPage, totalPages = excluded.totalPages,
                    bytes = excluded.bytes, title = excluded.title, ocrKeys = excluded.ocrKeys
                """, arguments: [id, file.mtime, file.size, file.fileIdentity, version, batch.nextPage, batch.totalPages, total, batch.title, json])
            for segment in batch.segments {
                try db.execute(sql: "INSERT OR REPLACE INTO pdf_pages(fileId, page, text, isOCR) VALUES (?, ?, ?, ?)",
                    arguments: [id, Int(segment.location.locationValue) ?? 0, segment.text, segment.kind == .ocr])
            }
        }
    }

    func completedPDF(fileId: Int64) throws -> ExtractedDocument {
        try dbPool.read { db in
            let title = try String.fetchOne(db, sql: "SELECT title FROM pdf_progress WHERE fileId = ?", arguments: [fileId])
            let segments = try Row.fetchAll(db, sql: "SELECT page, text, isOCR FROM pdf_pages WHERE fileId = ? ORDER BY page", arguments: [fileId]).map { row in
                DocumentSegment(text: row["text"], location: .page(row["page"]), kind: (row["isOCR"] as Bool) ? .ocr : .body)
            }
            return ExtractedDocument(title: title, segments: segments)
        }
    }
}
