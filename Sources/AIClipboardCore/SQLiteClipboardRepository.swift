import CSQLite
import Foundation

public enum DatabaseError: Error, CustomStringConvertible {
    case open(String)
    case execute(String)
    case prepare(String)
    case bind(String)
    case corrupt

    public var description: String {
        switch self {
        case .open(let message): "Database open failed: \(message)"
        case .execute(let message): "Database execution failed: \(message)"
        case .prepare(let message): "Database prepare failed: \(message)"
        case .bind(let message): "Database binding failed: \(message)"
        case .corrupt: "Database integrity check failed"
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public actor SQLiteClipboardRepository: ClipboardRepository {
    private var database: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let cipher: ContentEncrypting?

    public init(path: String, cipher: ContentEncrypting? = nil) throws {
        self.cipher = cipher
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = database.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(database)
            throw DatabaseError.open(message)
        }
        try Self.configure(database)
        try Self.migrate(database)
    }

    deinit { sqlite3_close(database) }

    public func integrityCheck() throws -> Bool {
        try scalarString("PRAGMA quick_check") == "ok"
    }

    public func save(_ item: ClipboardItem, embedding: [Float]?) async throws {
        let shouldEncrypt = item.isSensitive && cipher != nil
        let rawData = item.rawText.map { Data($0.utf8) }
        let normalizedData = item.normalizedText.map { Data($0.utf8) }
        let storedRaw = try rawData.map { shouldEncrypt ? try cipher!.encrypt($0) : $0 }
        let storedNormalized = try normalizedData.map { shouldEncrypt ? try cipher!.encrypt($0) : $0 }

        try transaction {
            let sql = """
                INSERT INTO clipboard_items (
                    id, content_type, raw_content, normalized_content, content_encrypted,
                    rich_text, image_path, file_references, source_bundle_id, source_app_name,
                    source_app_path, source_window_title, source_url, created_at, updated_at,
                    last_used_at, usage_count, is_pinned, is_favorite, is_sensitive,
                    sensitivity_type, retention_policy, content_hash, language, title, summary,
                    tags, processing_status, deleted_at
                ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,NULL)
                ON CONFLICT(id) DO UPDATE SET
                    content_type=excluded.content_type, raw_content=excluded.raw_content,
                    normalized_content=excluded.normalized_content,
                    content_encrypted=excluded.content_encrypted, rich_text=excluded.rich_text,
                    image_path=excluded.image_path, file_references=excluded.file_references,
                    source_bundle_id=excluded.source_bundle_id,
                    source_app_name=excluded.source_app_name,
                    source_app_path=excluded.source_app_path,
                    source_window_title=excluded.source_window_title,
                    source_url=excluded.source_url, created_at=excluded.created_at,
                    updated_at=excluded.updated_at, last_used_at=excluded.last_used_at,
                    usage_count=excluded.usage_count, is_pinned=excluded.is_pinned,
                    is_favorite=excluded.is_favorite, is_sensitive=excluded.is_sensitive,
                    sensitivity_type=excluded.sensitivity_type,
                    retention_policy=excluded.retention_policy,
                    content_hash=excluded.content_hash, language=excluded.language,
                    title=excluded.title, summary=excluded.summary, tags=excluded.tags,
                    processing_status=excluded.processing_status, deleted_at=NULL
                """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            let files = try encoder.encode(item.fileReferences)
            let tags = try encoder.encode(item.tags)
            let values: [SQLiteValue] = [
                .text(item.id.uuidString), .text(item.contentType.rawValue), .blob(storedRaw),
                .blob(storedNormalized), .int(shouldEncrypt ? 1 : 0), .blob(item.richTextData),
                .text(item.imagePath), .blob(files), .text(item.sourceApplication?.bundleIdentifier),
                .text(item.sourceApplication?.applicationName), .text(item.sourceApplication?.applicationPath),
                .text(item.sourceWindowTitle), .text(shouldEncrypt ? nil : item.sourceURL),
                .double(item.createdAt.timeIntervalSince1970),
                .double(item.updatedAt.timeIntervalSince1970), .double(item.lastUsedAt?.timeIntervalSince1970),
                .int(item.usageCount), .int(item.isPinned ? 1 : 0), .int(item.isFavorite ? 1 : 0),
                .int(item.isSensitive ? 1 : 0), .text(item.sensitivityType?.rawValue),
                .text(item.retentionPolicy.rawValue), .text(item.contentHash), .text(item.language),
                .text(item.title), .text(item.summary), .blob(tags), .text(item.processingStatus.rawValue)
            ]
            try bind(values, to: statement)
            try stepDone(statement)

            try execute("DELETE FROM clipboard_fts WHERE item_id = ?", [.text(item.id.uuidString)])
            if !shouldEncrypt {
                try execute(
                    "INSERT INTO clipboard_fts(item_id, title, content, source_app, tags) VALUES (?,?,?,?,?)",
                    [.text(item.id.uuidString), .text(item.title), .text(item.normalizedText),
                     .text(item.sourceApplication?.applicationName), .text(item.tags.joined(separator: " "))]
                )
            }
            if let embedding {
                try storeEmbedding(id: item.id, vector: embedding)
            }
            try execute(
                "INSERT INTO clipboard_events(id,item_id,event_type,created_at) VALUES (?,?,?,?)",
                [.text(UUID().uuidString), .text(item.id.uuidString), .text("created"),
                 .double(item.createdAt.timeIntervalSince1970)]
            )
        }
    }

    public func recent(limit: Int, filters: SearchFilters = .init()) async throws -> [ClipboardItem] {
        var sql = "SELECT * FROM clipboard_items WHERE deleted_at IS NULL"
        var values: [SQLiteValue] = []
        appendFilters(&sql, &values, filters: filters)
        sql += " ORDER BY is_pinned DESC, created_at DESC LIMIT ?"
        values.append(.int(limit))
        return try fetchItems(sql, values)
    }

    public func item(id: UUID) async throws -> ClipboardItem? {
        try fetchItems("SELECT * FROM clipboard_items WHERE id = ? AND deleted_at IS NULL", [.text(id.uuidString)]).first
    }

    public func duplicate(hash: String, since: Date) async throws -> ClipboardItem? {
        try fetchItems(
            """
            SELECT * FROM clipboard_items
            WHERE content_hash = ? AND created_at >= ? AND deleted_at IS NULL
            ORDER BY created_at DESC LIMIT 1
            """,
            [.text(hash), .double(since.timeIntervalSince1970)]
        ).first
    }

    public func recordReuse(id: UUID, at date: Date) async throws {
        try transaction {
            try execute(
                "UPDATE clipboard_items SET usage_count=usage_count+1,last_used_at=?,updated_at=? WHERE id=?",
                [.double(date.timeIntervalSince1970), .double(date.timeIntervalSince1970), .text(id.uuidString)]
            )
            try execute(
                "INSERT INTO clipboard_events(id,item_id,event_type,created_at) VALUES (?,?,?,?)",
                [.text(UUID().uuidString), .text(id.uuidString), .text("reused"), .double(date.timeIntervalSince1970)]
            )
        }
    }

    public func setPinned(id: UUID, value: Bool) async throws {
        try execute("UPDATE clipboard_items SET is_pinned=?,updated_at=? WHERE id=?",
                    [.int(value ? 1 : 0), .double(Date().timeIntervalSince1970), .text(id.uuidString)])
    }

    public func setFavorite(id: UUID, value: Bool) async throws {
        try execute("UPDATE clipboard_items SET is_favorite=?,updated_at=? WHERE id=?",
                    [.int(value ? 1 : 0), .double(Date().timeIntervalSince1970), .text(id.uuidString)])
    }

    public func updateContentHash(id: UUID, hash: String) async throws {
        try execute(
            "UPDATE clipboard_items SET content_hash=?,updated_at=? WHERE id=?",
            [.text(hash), .double(Date().timeIntervalSince1970), .text(id.uuidString)]
        )
    }

    public func setSensitivity(id: UUID, isSensitive: Bool, type: SensitivityType?) async throws {
        try transaction {
            let existing = try fetchItems(
                "SELECT * FROM clipboard_items WHERE id=? AND deleted_at IS NULL",
                [.text(id.uuidString)]
            ).first
            guard let existing else { return }
            let shouldEncrypt = isSensitive && cipher != nil
            let rawData = existing.rawText.map { Data($0.utf8) }
            let normalizedData = existing.normalizedText.map { Data($0.utf8) }
            let storedRaw = try rawData.map { shouldEncrypt ? try cipher!.encrypt($0) : $0 }
            let storedNormalized = try normalizedData.map { shouldEncrypt ? try cipher!.encrypt($0) : $0 }
            try execute(
                """
                UPDATE clipboard_items
                SET raw_content=?,normalized_content=?,content_encrypted=?,source_url=?,
                    is_sensitive=?,sensitivity_type=?,updated_at=?
                WHERE id=?
                """,
                [
                    .blob(storedRaw),
                    .blob(storedNormalized),
                    .int(shouldEncrypt ? 1 : 0),
                    .text(isSensitive ? nil : (existing.sourceURL ?? existing.normalizedText)),
                    .int(isSensitive ? 1 : 0),
                    .text(type?.rawValue),
                    .double(Date().timeIntervalSince1970),
                    .text(id.uuidString)
                ]
            )
            try execute("DELETE FROM clipboard_fts WHERE item_id=?", [.text(id.uuidString)])
            if !isSensitive {
                let searchableContent = existing.normalizedText ?? existing.sourceURL
                try execute(
                    "INSERT INTO clipboard_fts(item_id,title,content,source_app,tags) VALUES(?,?,?,?,?)",
                    [
                        .text(id.uuidString),
                        .text(existing.title),
                        .text(searchableContent),
                        .text(existing.sourceApplication?.applicationName),
                        .text(existing.tags.joined(separator: " "))
                    ]
                )
            }
        }
    }

    public func updateTitle(id: UUID, title: String?) async throws {
        try transaction {
            try execute("UPDATE clipboard_items SET title=?,updated_at=? WHERE id=?",
                        [.text(title), .double(Date().timeIntervalSince1970), .text(id.uuidString)])
            if let item = try fetchItems("SELECT * FROM clipboard_items WHERE id=?", [.text(id.uuidString)]).first,
               !item.isSensitive {
                try execute("UPDATE clipboard_fts SET title=? WHERE item_id=?", [.text(title), .text(id.uuidString)])
            }
        }
    }

    public func softDelete(id: UUID) async throws {
        try transaction {
            try execute("UPDATE clipboard_items SET deleted_at=? WHERE id=?",
                        [.double(Date().timeIntervalSince1970), .text(id.uuidString)])
            try execute("DELETE FROM clipboard_fts WHERE item_id=?", [.text(id.uuidString)])
        }
    }

    public func mergeDuplicate(keeping keeperID: UUID, removing duplicateID: UUID) async throws {
        guard keeperID != duplicateID else { return }
        let keeper = try fetchItems(
            "SELECT * FROM clipboard_items WHERE id=? AND deleted_at IS NULL",
            [.text(keeperID.uuidString)]
        ).first
        let duplicate = try fetchItems(
            "SELECT * FROM clipboard_items WHERE id=? AND deleted_at IS NULL",
            [.text(duplicateID.uuidString)]
        ).first
        let mustRemainProtected = keeper?.isSensitive == true || duplicate?.isSensitive == true
        let sensitivityType = keeper?.sensitivityType ?? duplicate?.sensitivityType
        try transaction {
            try execute(
                """
                UPDATE clipboard_items
                SET usage_count = usage_count + COALESCE(
                        (SELECT usage_count FROM clipboard_items WHERE id=?), 0
                    ),
                    is_pinned = MAX(is_pinned, COALESCE(
                        (SELECT is_pinned FROM clipboard_items WHERE id=?), 0
                    )),
                    is_favorite = MAX(is_favorite, COALESCE(
                        (SELECT is_favorite FROM clipboard_items WHERE id=?), 0
                    )),
                    created_at = MIN(created_at, COALESCE(
                        (SELECT created_at FROM clipboard_items WHERE id=?), created_at
                    )),
                    updated_at = ?
                WHERE id=?
                """,
                [
                    .text(duplicateID.uuidString),
                    .text(duplicateID.uuidString),
                    .text(duplicateID.uuidString),
                    .text(duplicateID.uuidString),
                    .double(Date().timeIntervalSince1970),
                    .text(keeperID.uuidString)
                ]
            )
            try execute("DELETE FROM clipboard_fts WHERE item_id=?", [.text(duplicateID.uuidString)])
            try execute("DELETE FROM clipboard_items WHERE id=?", [.text(duplicateID.uuidString)])
        }
        if mustRemainProtected {
            try await setSensitivity(
                id: keeperID,
                isSensitive: true,
                type: sensitivityType
            )
        }
    }

    public func emptyTrash() async throws {
        try execute("DELETE FROM clipboard_items WHERE deleted_at IS NOT NULL")
    }

    public func deleteAll() async throws {
        try transaction {
            try execute("DELETE FROM clipboard_items")
            try execute("DELETE FROM clipboard_fts")
        }
    }

    public func keywordSearch(_ query: SearchQuery) async throws -> [(ClipboardItem, Double, String?)] {
        let terms = query.semanticQuery
            .split { !$0.isLetter && !$0.isNumber }
            .map { "\"\(String($0).replacingOccurrences(of: "\"", with: "\"\""))\"*" }
        guard !terms.isEmpty else {
            return try await recent(limit: query.limit, filters: query.filters).map { ($0, 0, nil) }
        }
        var sql = """
            SELECT i.*, bm25(clipboard_fts, 0, 4, 1, 0.5, 0.5) AS rank,
                   snippet(clipboard_fts, 2, '‹', '›', '…', 20) AS matched
            FROM clipboard_fts JOIN clipboard_items i ON i.id=clipboard_fts.item_id
            WHERE clipboard_fts MATCH ? AND i.deleted_at IS NULL
            """
        var values: [SQLiteValue] = [.text(terms.joined(separator: " AND "))]
        appendFilters(&sql, &values, filters: query.filters, prefix: "i.")
        sql += " ORDER BY rank LIMIT ?"
        values.append(.int(query.limit))

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        var results: [(ClipboardItem, Double, String?)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let item = try decodeItem(statement)
            let rank = sqlite3_column_double(statement, 29)
            let snippet = columnText(statement, 30)
            results.append((item, 1 / (1 + abs(rank)), snippet))
        }
        return results
    }

    public func allEmbeddings(filters: SearchFilters, limit: Int) async throws -> [(ClipboardItem, [Float])] {
        var sql = """
            SELECT i.*, e.vector FROM clipboard_items i
            JOIN embeddings e ON e.item_id=i.id
            WHERE i.deleted_at IS NULL
            """
        var values: [SQLiteValue] = []
        appendFilters(&sql, &values, filters: filters, prefix: "i.")
        sql += " ORDER BY i.created_at DESC LIMIT ?"
        values.append(.int(limit))
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        var rows: [(ClipboardItem, [Float])] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let item = try decodeItem(statement)
            guard let data = columnBlob(statement, 29) else { continue }
            rows.append((item, decodeVector(data)))
        }
        return rows
    }

    public func updateEmbedding(id: UUID, embedding: [Float]) async throws {
        try storeEmbedding(id: id, vector: embedding)
        try execute("UPDATE clipboard_items SET processing_status=? WHERE id=?",
                    [.text(ProcessingStatus.indexed.rawValue), .text(id.uuidString)])
    }

    private static func configure(_ db: OpaquePointer?) throws {
        try run(db, "PRAGMA journal_mode=WAL")
        try run(db, "PRAGMA synchronous=NORMAL")
        try run(db, "PRAGMA foreign_keys=ON")
        try run(db, "PRAGMA busy_timeout=5000")
    }

    private static func migrate(_ db: OpaquePointer?) throws {
        let schema = """
        CREATE TABLE IF NOT EXISTS schema_migrations(version INTEGER PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS clipboard_items(
            id TEXT PRIMARY KEY,
            content_type TEXT NOT NULL,
            raw_content BLOB,
            normalized_content BLOB,
            content_encrypted INTEGER NOT NULL DEFAULT 0,
            rich_text BLOB,
            image_path TEXT,
            file_references BLOB NOT NULL,
            source_bundle_id TEXT,
            source_app_name TEXT,
            source_app_path TEXT,
            source_window_title TEXT,
            source_url TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            last_used_at REAL,
            usage_count INTEGER NOT NULL DEFAULT 1,
            is_pinned INTEGER NOT NULL DEFAULT 0,
            is_favorite INTEGER NOT NULL DEFAULT 0,
            is_sensitive INTEGER NOT NULL DEFAULT 0,
            sensitivity_type TEXT,
            retention_policy TEXT NOT NULL,
            content_hash TEXT NOT NULL,
            language TEXT,
            title TEXT,
            summary TEXT,
            tags BLOB NOT NULL,
            processing_status TEXT NOT NULL,
            deleted_at REAL
        );
        CREATE INDEX IF NOT EXISTS idx_items_created ON clipboard_items(created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_items_hash ON clipboard_items(content_hash,content_type,created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_items_source ON clipboard_items(source_app_name);
        CREATE TABLE IF NOT EXISTS clipboard_events(
            id TEXT PRIMARY KEY,
            item_id TEXT NOT NULL REFERENCES clipboard_items(id) ON DELETE CASCADE,
            event_type TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS embeddings(
            item_id TEXT PRIMARY KEY REFERENCES clipboard_items(id) ON DELETE CASCADE,
            dimensions INTEGER NOT NULL,
            vector BLOB NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_fts USING fts5(
            item_id UNINDEXED, title, content, source_app, tags,
            tokenize='unicode61 remove_diacritics 2'
        );
        INSERT OR IGNORE INTO schema_migrations(version) VALUES(1);
        """
        try run(db, schema)
    }

    private static func run(_ db: OpaquePointer?, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            throw DatabaseError.execute(text)
        }
    }

    private enum SQLiteValue {
        case text(String?), blob(Data?), int(Int), double(Double?)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.prepare(errorMessage)
        }
        return statement
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let string):
                if let string { result = sqlite3_bind_text(statement, index, string, -1, sqliteTransient) }
                else { result = sqlite3_bind_null(statement, index) }
            case .blob(let data):
                if let data {
                    result = data.withUnsafeBytes {
                        sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), sqliteTransient)
                    }
                } else { result = sqlite3_bind_null(statement, index) }
            case .int(let integer):
                result = sqlite3_bind_int64(statement, index, sqlite3_int64(integer))
            case .double(let number):
                if let number { result = sqlite3_bind_double(statement, index, number) }
                else { result = sqlite3_bind_null(statement, index) }
            }
            guard result == SQLITE_OK else { throw DatabaseError.bind(errorMessage) }
        }
    }

    private func execute(_ sql: String, _ values: [SQLiteValue] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        try stepDone(statement)
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.execute(errorMessage) }
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func scalarString(_ sql: String) throws -> String? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return columnText(statement, 0)
    }

    private var errorMessage: String {
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }

    private func storeEmbedding(id: UUID, vector: [Float]) throws {
        let data = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        try execute(
            """
            INSERT INTO embeddings(item_id,dimensions,vector,created_at) VALUES(?,?,?,?)
            ON CONFLICT(item_id) DO UPDATE SET dimensions=excluded.dimensions,vector=excluded.vector,created_at=excluded.created_at
            """,
            [.text(id.uuidString), .int(vector.count), .blob(data), .double(Date().timeIntervalSince1970)]
        )
    }

    private func decodeVector(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }

    private func fetchItems(_ sql: String, _ values: [SQLiteValue]) throws -> [ClipboardItem] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        var items: [ClipboardItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            items.append(try decodeItem(statement))
        }
        return items
    }

    private func decodeItem(_ statement: OpaquePointer) throws -> ClipboardItem {
        guard let idText = columnText(statement, 0), let id = UUID(uuidString: idText),
              let typeText = columnText(statement, 1), let type = ClipboardContentType(rawValue: typeText),
              let retentionText = columnText(statement, 21), let retention = RetentionPolicy(rawValue: retentionText),
              let hash = columnText(statement, 22),
              let statusText = columnText(statement, 27), let status = ProcessingStatus(rawValue: statusText)
        else { throw DatabaseError.corrupt }
        let encrypted = sqlite3_column_int(statement, 4) != 0
        let rawData = columnBlob(statement, 2)
        let normalizedData = columnBlob(statement, 3)
        let raw = try decodeContent(rawData, encrypted: encrypted)
        let normalized = try decodeContent(normalizedData, encrypted: encrypted)
        let files = try columnBlob(statement, 7).map { try decoder.decode([FileReference].self, from: $0) } ?? []
        let tags = try columnBlob(statement, 26).map { try decoder.decode([String].self, from: $0) } ?? []
        let source: SourceApplication?
        if let bundle = columnText(statement, 8), let name = columnText(statement, 9) {
            source = SourceApplication(bundleIdentifier: bundle, applicationName: name, applicationPath: columnText(statement, 10))
        } else { source = nil }
        return ClipboardItem(
            id: id, contentType: type, rawText: raw, normalizedText: normalized,
            richTextData: columnBlob(statement, 5), imagePath: columnText(statement, 6),
            fileReferences: files, sourceApplication: source, sourceWindowTitle: columnText(statement, 11),
            sourceURL: columnText(statement, 12), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 13)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 14)),
            lastUsedAt: sqlite3_column_type(statement, 15) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 15)),
            usageCount: Int(sqlite3_column_int(statement, 16)), isPinned: sqlite3_column_int(statement, 17) != 0,
            isFavorite: sqlite3_column_int(statement, 18) != 0, isSensitive: sqlite3_column_int(statement, 19) != 0,
            sensitivityType: columnText(statement, 20).flatMap(SensitivityType.init(rawValue:)),
            retentionPolicy: retention, contentHash: hash, language: columnText(statement, 23),
            title: columnText(statement, 24), summary: columnText(statement, 25), tags: tags, processingStatus: status
        )
    }

    private func decodeContent(_ data: Data?, encrypted: Bool) throws -> String? {
        guard var data else { return nil }
        if encrypted {
            guard let cipher else { throw EncryptionError.invalidCiphertext }
            // A protected value written by a previous signing identity may no
            // longer be decryptable. Keep the item metadata available without
            // exposing ciphertext or preventing the rest of history from loading.
            guard let decrypted = try? cipher.decrypt(data) else { return nil }
            data = decrypted
        }
        return String(data: data, encoding: .utf8)
    }

    private func appendFilters(
        _ sql: inout String,
        _ values: inout [SQLiteValue],
        filters: SearchFilters,
        prefix: String = ""
    ) {
        if let from = filters.from {
            sql += " AND \(prefix)created_at >= ?"
            values.append(.double(from.timeIntervalSince1970))
        }
        if let to = filters.to {
            sql += " AND \(prefix)created_at < ?"
            values.append(.double(to.timeIntervalSince1970))
        }
        if let app = filters.applicationName {
            sql += " AND \(prefix)source_app_name LIKE ?"
            values.append(.text("%\(app)%"))
        }
        if let type = filters.contentType {
            sql += " AND \(prefix)content_type = ?"
            values.append(.text(type.rawValue))
        }
        if filters.pinnedOnly { sql += " AND \(prefix)is_pinned = 1" }
        if filters.sensitiveOnly { sql += " AND \(prefix)is_sensitive = 1" }
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private func columnBlob(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, index)))
    }
}
