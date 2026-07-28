import Foundation

/// Volatile repository used by the server-first desktop client. Clipboard
/// content exists only for the lifetime of the process and is never written to
/// the application support directory.
public actor InMemoryClipboardRepository: ClipboardRepository {
    private var items: [UUID: ClipboardItem] = [:]
    private var embeddings: [UUID: [Float]] = [:]

    public init() {}

    public func save(_ item: ClipboardItem, embedding: [Float]?) async throws {
        items[item.id] = item
        if let embedding { embeddings[item.id] = embedding }
    }

    public func recent(limit: Int, filters: SearchFilters) async throws -> [ClipboardItem] {
        filtered(filters)
            .sorted {
                if $0.isPinned != $1.isPinned { return $0.isPinned }
                return $0.createdAt > $1.createdAt
            }
            .prefix(limit)
            .map { $0 }
    }

    public func item(id: UUID) async throws -> ClipboardItem? {
        items[id]
    }

    public func duplicate(hash: String, since: Date) async throws -> ClipboardItem? {
        items.values
            .filter { $0.contentHash == hash && $0.createdAt >= since }
            .max { $0.updatedAt < $1.updatedAt }
    }

    public func recordReuse(id: UUID, at date: Date) async throws {
        guard var item = items[id] else { return }
        item.usageCount += 1
        item.lastUsedAt = date
        item.updatedAt = date
        items[id] = item
    }

    public func setPinned(id: UUID, value: Bool) async throws {
        try update(id) { $0.isPinned = value }
    }

    public func setFavorite(id: UUID, value: Bool) async throws {
        try update(id) { $0.isFavorite = value }
    }

    public func setSensitivity(
        id: UUID,
        isSensitive: Bool,
        type: SensitivityType?
    ) async throws {
        try update(id) {
            $0.isSensitive = isSensitive
            $0.sensitivityType = isSensitive ? type : nil
        }
        if isSensitive { embeddings[id] = nil }
    }

    public func updateContentHash(id: UUID, hash: String) async throws {
        try update(id) { $0.contentHash = hash }
    }

    public func updateTitle(id: UUID, title: String?) async throws {
        try update(id) { $0.title = title }
    }

    public func softDelete(id: UUID) async throws {
        items[id] = nil
        embeddings[id] = nil
    }

    public func mergeDuplicate(keeping keeperID: UUID, removing duplicateID: UUID) async throws {
        guard var keeper = items[keeperID], let duplicate = items[duplicateID] else { return }
        keeper.usageCount += duplicate.usageCount
        keeper.isPinned = keeper.isPinned || duplicate.isPinned
        keeper.isFavorite = keeper.isFavorite || duplicate.isFavorite
        keeper.isSensitive = keeper.isSensitive || duplicate.isSensitive
        if keeper.sensitivityType == nil {
            keeper.sensitivityType = duplicate.sensitivityType
        }
        keeper.updatedAt = max(keeper.updatedAt, duplicate.updatedAt)
        items[keeperID] = keeper
        items[duplicateID] = nil
        embeddings[duplicateID] = nil
        if keeper.isSensitive {
            embeddings[keeperID] = nil
        }
    }

    public func emptyTrash() async throws {}

    public func deleteAll() async throws {
        items.removeAll(keepingCapacity: false)
        embeddings.removeAll(keepingCapacity: false)
    }

    public func keywordSearch(
        _ query: SearchQuery
    ) async throws -> [(ClipboardItem, Double, String?)] {
        let terms = query.semanticQuery.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        guard !terms.isEmpty else { return [] }
        return filtered(query.filters)
            .filter { !$0.isSensitive }
            .compactMap { item in
                let content = [
                    item.title,
                    item.normalizedText,
                    item.sourceApplication?.applicationName,
                    item.tags.joined(separator: " ")
                ].compactMap { $0 }.joined(separator: "\n")
                let lower = content.lowercased()
                let hits = terms.filter(lower.contains).count
                guard hits > 0 else { return nil }
                return (item, Double(hits) / Double(terms.count), item.normalizedText)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(query.limit)
            .map { $0 }
    }

    public func allEmbeddings(
        filters: SearchFilters,
        limit: Int
    ) async throws -> [(ClipboardItem, [Float])] {
        filtered(filters)
            .filter { !$0.isSensitive && embeddings[$0.id] != nil }
            .prefix(limit)
            .compactMap { item in embeddings[item.id].map { (item, $0) } }
    }

    public func updateEmbedding(id: UUID, embedding: [Float]) async throws {
        embeddings[id] = embedding
        try update(id) { $0.processingStatus = .indexed }
    }

    private func update(_ id: UUID, mutation: (inout ClipboardItem) -> Void) throws {
        guard var item = items[id] else { return }
        mutation(&item)
        item.updatedAt = Date()
        items[id] = item
    }

    private func filtered(_ filters: SearchFilters) -> [ClipboardItem] {
        items.values.filter { item in
            if let from = filters.from, item.createdAt < from { return false }
            if let to = filters.to, item.createdAt >= to { return false }
            if let application = filters.applicationName,
               item.sourceApplication?.applicationName.localizedCaseInsensitiveContains(application) != true {
                return false
            }
            if let type = filters.contentType, item.contentType != type { return false }
            if filters.pinnedOnly, !item.isPinned { return false }
            if filters.sensitiveOnly, !item.isSensitive { return false }
            if let sensitive = filters.sensitivity, item.isSensitive != sensitive { return false }
            if let contains = filters.containsText {
                let haystack = [item.rawText, item.normalizedText, item.title, item.summary]
                    .compactMap { $0 }.joined(separator: "\n")
                if !haystack.localizedCaseInsensitiveContains(contains) { return false }
            }
            if let project = filters.projectName {
                let context = ([item.sourceWindowTitle] + item.tags.map(Optional.some))
                    .compactMap { $0 }.joined(separator: " ")
                if !context.localizedCaseInsensitiveContains(project) { return false }
            }
            return true
        }
    }
}
