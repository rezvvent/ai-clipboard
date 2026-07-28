import Foundation

public protocol TextNormalizing: Sendable {
    func normalize(_ text: String) -> String
}

public protocol ContentDetecting: Sendable {
    func detect(text: String, hasImage: Bool, files: [FileReference]) -> ClipboardContentType
}

public protocol SecretDetecting: Sendable {
    func detect(in text: String) -> SecretFinding?
}

public protocol EmbeddingProviding: Sendable {
    var dimensions: Int { get }
    func embed(_ text: String) async throws -> [Float]
}

public protocol ContentEncrypting: Sendable {
    func encrypt(_ data: Data) throws -> Data
    func decrypt(_ data: Data) throws -> Data
}

public protocol ClipboardRepository: Sendable {
    func save(_ item: ClipboardItem, embedding: [Float]?) async throws
    func recent(limit: Int, filters: SearchFilters) async throws -> [ClipboardItem]
    func item(id: UUID) async throws -> ClipboardItem?
    func duplicate(hash: String, since: Date) async throws -> ClipboardItem?
    func recordReuse(id: UUID, at date: Date) async throws
    func setPinned(id: UUID, value: Bool) async throws
    func setFavorite(id: UUID, value: Bool) async throws
    func setSensitivity(id: UUID, isSensitive: Bool, type: SensitivityType?) async throws
    func updateContentHash(id: UUID, hash: String) async throws
    func updateTitle(id: UUID, title: String?) async throws
    func softDelete(id: UUID) async throws
    func mergeDuplicate(keeping keeperID: UUID, removing duplicateID: UUID) async throws
    func emptyTrash() async throws
    func deleteAll() async throws
    func keywordSearch(_ query: SearchQuery) async throws -> [(ClipboardItem, Double, String?)]
    func allEmbeddings(filters: SearchFilters, limit: Int) async throws -> [(ClipboardItem, [Float])]
    func updateEmbedding(id: UUID, embedding: [Float]) async throws
}

public protocol PrivacyChecking: Sendable {
    func shouldCapture(
        source: SourceApplication?,
        contentType: ClipboardContentType,
        normalizedText: String
    ) async -> Bool
    func isPaused() async -> Bool
}

public protocol DiagnosticLogging: Sendable {
    func event(_ name: String, fields: [String: String])
    func error(_ code: String, operationID: UUID)
}

public struct RedactingLogger: DiagnosticLogging {
    public init() {}
    public func event(_ name: String, fields: [String: String] = [:]) {
        let safe = fields.filter { !["content", "query", "url", "path"].contains($0.key.lowercased()) }
        NSLog("[AIClipboard] %@ %@", name, safe.description)
    }
    public func error(_ code: String, operationID: UUID) {
        NSLog("[AIClipboard] error=%@ operation=%@", code, operationID.uuidString)
    }
}
