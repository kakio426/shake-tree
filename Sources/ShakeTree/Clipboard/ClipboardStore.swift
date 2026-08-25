import CryptoKit
import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// OpaquePointer 자체는 Sendable이 아니지만 연결은 ClipboardStore actor 한 곳에서만 쓴다.
/// 별도 소유 객체가 프로세스/테스트 종료 시 sqlite handle을 확실히 닫는다.
private final class SQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer

    init(_ handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        sqlite3_close(handle)
    }
}

/// 클립보드 히스토리 SQLite 저장소.
///
/// 이미지 변환·해시·BLOB I/O가 메뉴바 UI를 멈추지 않도록 actor가 전용 직렬 실행
/// 컨텍스트에서 모든 DB 작업을 수행한다. SQLite 연결도 이 actor 밖으로 노출하지 않는다.
actor ClipboardStore {
    static let shared = ClipboardStore()
    static let maxImageBytes = 10 * 1024 * 1024

    private let connection: SQLiteConnection?
    private var db: OpaquePointer? { connection?.handle }

    private var maxItems: Int {
        let value = UserDefaults.standard.integer(forKey: "historyLimit")
        return value > 0 ? value : 500
    }

    init(databaseURL: URL? = nil) {
        let url = databaseURL ?? Self.defaultDatabaseURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            connection = nil
            NSLog("ShakeTree: SQLite 열기 실패 \(url.path)")
            return
        }
        connection = SQLiteConnection(handle)
        sqlite3_busy_timeout(handle, 2_000)

        _ = Self.execute(on: handle, sql: "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        _ = Self.execute(
            on: handle,
            sql:
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

    /// 새 항목 저장. 같은 내용이 이미 있으면 그 항목을 맨 위로 올린다(핀 상태 유지).
    /// TIFF 등 원본 이미지 변환도 actor 안에서 처리해 메인 스레드를 점유하지 않는다.
    @discardableResult
    func add(
        kind: ClipboardItem.Kind,
        text: String?,
        imageData: Data?,
        imageIsPNG: Bool = true,
        createdAt: Date = Date()
    ) -> Bool {
        guard let db else { return false }

        var storedImage = imageData
        if kind == .image {
            guard let imageData,
                let png = Self.normalizedPNG(from: imageData, alreadyPNG: imageIsPNG)
            else { return false }
            // 초대형 이미지로 DB가 비대해지는 것을 막는다. 변환 후 실제 저장 크기 기준.
            guard png.count <= Self.maxImageBytes else { return false }
            storedImage = png
        }

        let hash = contentHash(kind: kind, text: text, imageData: storedImage)
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(db, "SELECT id FROM items WHERE hash = ? LIMIT 1", -1, &statement, nil)
                == SQLITE_OK,
            let statement
        else {
            logLastError("중복 조회 준비 실패")
            return false
        }
        sqlite3_bind_text(statement, 1, hash, -1, SQLITE_TRANSIENT)
        let existingID = sqlite3_step(statement) == SQLITE_ROW
            ? sqlite3_column_int64(statement, 0) : nil
        sqlite3_finalize(statement)

        if let existingID {
            var update: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    db, "UPDATE items SET created_at = ? WHERE id = ?", -1, &update, nil)
                    == SQLITE_OK,
                let update
            else {
                logLastError("기존 항목 갱신 준비 실패")
                return false
            }
            sqlite3_bind_double(update, 1, createdAt.timeIntervalSince1970)
            sqlite3_bind_int64(update, 2, existingID)
            let succeeded = sqlite3_step(update) == SQLITE_DONE
            sqlite3_finalize(update)
            if !succeeded { logLastError("기존 항목 갱신 실패") }
            return succeeded
        }

        var insert: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                "INSERT INTO items (kind, text, image, hash, created_at, pinned) VALUES (?,?,?,?,?,0)",
                -1, &insert, nil) == SQLITE_OK,
            let insert
        else {
            logLastError("새 항목 저장 준비 실패")
            return false
        }
        sqlite3_bind_text(insert, 1, kind.rawValue, -1, SQLITE_TRANSIENT)
        if let text {
            sqlite3_bind_text(insert, 2, text, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(insert, 2)
        }
        if let storedImage {
            _ = storedImage.withUnsafeBytes {
                sqlite3_bind_blob(insert, 3, $0.baseAddress, Int32(storedImage.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(insert, 3)
        }
        sqlite3_bind_text(insert, 4, hash, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(insert, 5, createdAt.timeIntervalSince1970)
        let succeeded = sqlite3_step(insert) == SQLITE_DONE
        sqlite3_finalize(insert)
        guard succeeded else {
            logLastError("새 항목 저장 실패")
            return false
        }

        trim()
        return true
    }

    @discardableResult
    func setPinned(_ pinned: Bool, id: Int64) -> Bool {
        guard let db else { return false }
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db, "UPDATE items SET pinned = ? WHERE id = ?", -1, &statement, nil)
                == SQLITE_OK,
            let statement
        else {
            logLastError("핀 변경 준비 실패")
            return false
        }
        sqlite3_bind_int(statement, 1, pinned ? 1 : 0)
        sqlite3_bind_int64(statement, 2, id)
        let succeeded = sqlite3_step(statement) == SQLITE_DONE
        sqlite3_finalize(statement)
        if !succeeded { logLastError("핀 변경 실패") }
        return succeeded
    }

    @discardableResult
    func delete(id: Int64) -> Bool {
        guard let db else { return false }
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(db, "DELETE FROM items WHERE id = ?", -1, &statement, nil)
                == SQLITE_OK,
            let statement
        else {
            logLastError("항목 삭제 준비 실패")
            return false
        }
        sqlite3_bind_int64(statement, 1, id)
        let succeeded = sqlite3_step(statement) == SQLITE_DONE
        sqlite3_finalize(statement)
        if !succeeded { logLastError("항목 삭제 실패") }
        return succeeded
    }

    @discardableResult
    func deleteAllUnpinned() -> Bool {
        execute("DELETE FROM items WHERE pinned = 0")
    }

    /// 핀 항목 먼저, 이후 최신순. query가 있으면 텍스트 부분일치 필터.
    func items(matching query: String = "", limit: Int = 300) -> [ClipboardItem] {
        guard let db else { return [] }
        let safeLimit = min(max(limit, 1), 1_000)
        var sql = "SELECT id, kind, text, image, created_at, pinned FROM items"
        if !query.isEmpty { sql += " WHERE text LIKE ? ESCAPE '\\'" }
        sql += " ORDER BY pinned DESC, created_at DESC LIMIT \(safeLimit)"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            logLastError("항목 조회 준비 실패")
            return []
        }
        defer { sqlite3_finalize(statement) }

        if !query.isEmpty {
            let escaped = query
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            sqlite3_bind_text(statement, 1, "%\(escaped)%", -1, SQLITE_TRANSIENT)
        }

        var result: [ClipboardItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let kindText = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let kind = ClipboardItem.Kind(rawValue: kindText) ?? .text
            let text = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            var imageData: Data?
            if let blob = sqlite3_column_blob(statement, 3) {
                imageData = Data(
                    bytes: blob, count: Int(sqlite3_column_bytes(statement, 3)))
            }
            result.append(
                ClipboardItem(
                    id: id,
                    kind: kind,
                    text: text,
                    imageData: imageData,
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                    pinned: sqlite3_column_int(statement, 5) != 0))
        }
        return result
    }

    private static var defaultDatabaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShakeTree", isDirectory: true)
            .appendingPathComponent("clipboard.sqlite")
    }

    private func execute(_ sql: String) -> Bool {
        Self.execute(on: db, sql: sql)
    }

    private nonisolated static func execute(on db: OpaquePointer?, sql: String) -> Bool {
        guard let db else { return false }
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            if let error {
                NSLog("ShakeTree SQLite: \(String(cString: error))")
                sqlite3_free(error)
            }
            return false
        }
        return true
    }

    private func trim() {
        _ = execute(
            """
            DELETE FROM items WHERE pinned = 0 AND id NOT IN (
                SELECT id FROM items WHERE pinned = 0
                ORDER BY created_at DESC LIMIT \(maxItems)
            )
            """)
    }

    private func logLastError(_ context: String) {
        guard let db, let message = sqlite3_errmsg(db) else { return }
        NSLog("ShakeTree SQLite \(context): \(String(cString: message))")
    }

    private func contentHash(kind: ClipboardItem.Kind, text: String?, imageData: Data?) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(kind.rawValue.utf8))
        if let text { hasher.update(data: Data(text.utf8)) }
        if let imageData { hasher.update(data: imageData) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// ImageIO는 입력 Data만 사용하므로 AppKit 메인 스레드 없이 안전하게 검증·변환한다.
    private static func normalizedPNG(from data: Data, alreadyPNG: Bool) -> Data? {
        guard !data.isEmpty,
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0
        else { return nil }
        if alreadyPNG { return data }

        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
