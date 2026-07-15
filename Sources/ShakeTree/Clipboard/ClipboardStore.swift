import Foundation
import SQLite3
import CryptoKit

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 클립보드 히스토리 SQLite 저장소 (~/Library/Application Support/ShakeTree/clipboard.sqlite)
@MainActor
final class ClipboardStore {
    static let shared = ClipboardStore()
    private var db: OpaquePointer?

    var maxItems: Int {
        let v = UserDefaults.standard.integer(forKey: "historyLimit")
        return v > 0 ? v : 500
    }

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShakeTree", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("clipboard.sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            NSLog("ShakeTree: SQLite 열기 실패 \(path)")
            return
        }
        exec(
            """
            CREATE TABLE IF NOT EXISTS items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                kind TEXT NOT NULL,
                text TEXT,
                image BLOB,
                hash TEXT,
                created_at REAL NOT NULL,
                pinned INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_items_hash ON items(hash);
            CREATE INDEX IF NOT EXISTS idx_items_created ON items(created_at DESC);
            """)
    }

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK, let err {
            NSLog("ShakeTree SQLite: \(String(cString: err))")
            sqlite3_free(err)
        }
    }

    // MARK: - 쓰기

    /// 새 항목 저장. 같은 내용이 이미 있으면 그 항목을 맨 위로 올린다(핀 상태 유지).
    func add(kind: ClipboardItem.Kind, text: String?, imageData: Data?) {
        let hash = contentHash(kind: kind, text: text, imageData: imageData)

        var existingId: Int64?
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT id FROM items WHERE hash = ? LIMIT 1", -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, hash, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW { existingId = sqlite3_column_int64(stmt, 0) }
        sqlite3_finalize(stmt)

        if let existingId {
            sqlite3_prepare_v2(db, "UPDATE items SET created_at = ? WHERE id = ?", -1, &stmt, nil)
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 2, existingId)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            return
        }

        sqlite3_prepare_v2(
            db,
            "INSERT INTO items (kind, text, image, hash, created_at, pinned) VALUES (?,?,?,?,?,0)",
            -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, kind.rawValue, -1, SQLITE_TRANSIENT)
        if let text {
            sqlite3_bind_text(stmt, 2, text, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        if let imageData {
            _ = imageData.withUnsafeBytes {
                sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(imageData.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        sqlite3_bind_text(stmt, 4, hash, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)

        trim()
    }

    func setPinned(_ pinned: Bool, id: Int64) {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "UPDATE items SET pinned = ? WHERE id = ?", -1, &stmt, nil)
        sqlite3_bind_int(stmt, 1, pinned ? 1 : 0)
        sqlite3_bind_int64(stmt, 2, id)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func delete(id: Int64) {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "DELETE FROM items WHERE id = ?", -1, &stmt, nil)
        sqlite3_bind_int64(stmt, 1, id)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func deleteAllUnpinned() {
        exec("DELETE FROM items WHERE pinned = 0")
    }

    /// 핀 안 된 항목이 상한을 넘으면 오래된 것부터 삭제
    private func trim() {
        exec(
            """
            DELETE FROM items WHERE pinned = 0 AND id NOT IN (
                SELECT id FROM items WHERE pinned = 0
                ORDER BY created_at DESC LIMIT \(maxItems)
            )
            """)
    }

    // MARK: - 읽기

    /// 핀 항목 먼저, 이후 최신순. query가 있으면 텍스트 부분일치 필터.
    func items(matching query: String = "", limit: Int = 300) -> [ClipboardItem] {
        var sql = "SELECT id, kind, text, image, created_at, pinned FROM items"
        if !query.isEmpty { sql += " WHERE text LIKE ? ESCAPE '\\'" }
        sql += " ORDER BY pinned DESC, created_at DESC LIMIT \(limit)"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        if !query.isEmpty {
            let escaped = query
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            sqlite3_bind_text(stmt, 1, "%\(escaped)%", -1, SQLITE_TRANSIENT)
        }

        var result: [ClipboardItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let kind = ClipboardItem.Kind(
                rawValue: String(cString: sqlite3_column_text(stmt, 1))) ?? .text
            let text = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            var imageData: Data?
            if let blob = sqlite3_column_blob(stmt, 3) {
                imageData = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 3)))
            }
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            let pinned = sqlite3_column_int(stmt, 5) != 0
            result.append(
                ClipboardItem(
                    id: id, kind: kind, text: text, imageData: imageData,
                    createdAt: createdAt, pinned: pinned))
        }
        sqlite3_finalize(stmt)
        return result
    }

    private func contentHash(kind: ClipboardItem.Kind, text: String?, imageData: Data?) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(kind.rawValue.utf8))
        if let text { hasher.update(data: Data(text.utf8)) }
        if let imageData { hasher.update(data: imageData) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
