import AIClipboardCore
import Foundation

struct ServerAIResult {
    var answer: String
    var itemIDs: [UUID]
    var model: String
}

@MainActor
final class SecureSyncCoordinator: ObservableObject {
    @Published private(set) var isConfigured = false
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var aiAvailable = false
    @Published private(set) var aiModel = "gemini-3.5-flash"
    @Published private(set) var aiProvider = "google"
    @Published private(set) var aiStatusDetail = "not_checked"
    @Published var endpoint = ""
    @Published var errorMessage: String?
    var onConfigured: (() -> Void)?

    private struct Configuration: Codable {
        var endpoint: String
        var accessToken: String
        var refreshToken: String
        var deviceID: UUID
        var cursor: Int64
        var enabled: Bool
        var accountEmail: String?
    }

    private struct AuthRequest: Encodable {
        var email: String
        var password: String
        var displayName: String?
        var deviceID: UUID

        enum CodingKeys: String, CodingKey {
            case email, password
            case displayName = "display_name"
            case deviceID = "device_id"
        }
    }

    private struct RefreshRequest: Encodable {
        var refreshToken: String
        var deviceID: UUID

        enum CodingKeys: String, CodingKey {
            case refreshToken = "refresh_token"
            case deviceID = "device_id"
        }
    }

    private struct TokenPair: Decodable {
        var accessToken: String
        var refreshToken: String
        var userID: UUID?
        var email: String?
        var displayName: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case userID = "user_id"
            case email
            case displayName = "display_name"
        }
    }

    private struct ServerItem: Codable {
        var itemID: UUID
        var revision: Int64
        var deleted: Bool
        var payload: Data

        enum CodingKeys: String, CodingKey {
            case itemID = "item_id"
            case revision, deleted, payload
        }
    }

    private struct ServerBatch: Encodable {
        var deviceID: UUID
        var items: [ServerItem]

        enum CodingKeys: String, CodingKey {
            case deviceID = "device_id"
            case items
        }
    }

    private struct ServerBatchResponse: Decodable {
        var accepted: Int
        var cursor: Int64
    }

    private struct ServerChangesResponse: Decodable {
        var cursor: Int64
        var hasMore: Bool
        var items: [ServerItem]

        enum CodingKeys: String, CodingKey {
            case cursor, items
            case hasMore = "has_more"
        }
    }

    private struct AISearchRequest: Encodable {
        var query: String
        var locale: String
    }

    private struct AISearchResponse: Decodable {
        var answer: String
        var itemIDs: [UUID]
        var model: String

        enum CodingKeys: String, CodingKey {
            case answer, model
            case itemIDs = "item_ids"
        }
    }

    private struct AIStatusResponse: Decodable {
        var available: Bool
        var model: String
        var provider: String?
        var detail: String
    }

    private struct ErrorResponse: Decodable {
        var detail: String
    }

    private let repository: any ClipboardRepository
    private let configurationURL: URL
    private var configuration: Configuration?

    init(
        directory: URL,
        repository: any ClipboardRepository
    ) throws {
        self.repository = repository
        configurationURL = directory.appendingPathComponent("sync-session.json")
        let managedEndpoint = Self.managedEndpoint
        endpoint = managedEndpoint

        // v0.8+ never uses a local clipboard encryption key. Remove the obsolete
        // v0.7 E2EE key immediately; encryption-at-rest now belongs to the server.
        let obsoleteKey = directory.appendingPathComponent("sync-master.key")
        if FileManager.default.fileExists(atPath: obsoleteKey.path) {
            try FileManager.default.removeItem(at: obsoleteKey)
        }

        if let data = try? Data(contentsOf: configurationURL),
           var loaded = try? JSONDecoder().decode(Configuration.self, from: data),
           loaded.enabled,
           (
               managedEndpoint.isEmpty
                   ? !Self.isLocalEndpoint(loaded.endpoint)
                   : loaded.endpoint.trimmingCharacters(
                       in: CharacterSet(charactersIn: "/")
                   ) == managedEndpoint
           ) {
            loaded.cursor = 0
            configuration = loaded
            endpoint = loaded.endpoint
        }
    }

    var usesManagedEndpoint: Bool {
        !Self.managedEndpoint.isEmpty
    }

    func activateAccount(email: String?) {
        let normalizedEmail = email?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalizedEmail,
              let configuration,
              configuration.accountEmail == normalizedEmail else {
            deactivate()
            return
        }
        isConfigured = true
        endpoint = configuration.endpoint
        aiStatusDetail = "not_checked"
    }

    func disconnect() {
        configuration = nil
        deactivate()
        try? FileManager.default.removeItem(at: configurationURL)
    }

    private func deactivate() {
        isConfigured = false
        isSyncing = false
        lastSyncAt = nil
        aiAvailable = false
        aiStatusDetail = "storage_not_connected"
        errorMessage = nil
    }

    func createVault(session: UserSession, password: String) {
        configure(session: session, password: password, register: true)
    }

    func connectVault(session: UserSession, password: String) {
        configure(session: session, password: password, register: false)
    }

    func authenticateEmail(
        email: String,
        password: String,
        displayName: String?,
        register: Bool
    ) async throws -> UserSession {
        guard password.count >= (register ? 12 : 1) else {
            throw AccountError.weakPassword
        }
        guard let normalizedEndpoint = normalizedEndpoint(endpoint) else {
            throw AccountError.network("server_not_configured")
        }
        let normalizedEmail = email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let deviceID = configuration?.deviceID ?? UUID()
        let pair: TokenPair
        do {
            pair = try await request(
                endpoint: normalizedEndpoint,
                path: register ? "/v1/auth/register" : "/v1/auth/login",
                method: "POST",
                body: AuthRequest(
                    email: normalizedEmail,
                    password: password,
                    displayName: register ? displayName : nil,
                    deviceID: deviceID
                ),
                bearer: nil
            )
        } catch let SyncTransportError.server(_, detail) {
            switch detail {
            case "account_exists":
                throw AccountError.accountExists
            case "invalid_credentials":
                throw AccountError.invalidCredentials
            default:
                throw AccountError.network(detail ?? "server_error")
            }
        }
        let configured = Configuration(
            endpoint: normalizedEndpoint.absoluteString.trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            ),
            accessToken: pair.accessToken,
            refreshToken: pair.refreshToken,
            deviceID: deviceID,
            cursor: 0,
            enabled: true,
            accountEmail: normalizedEmail
        )
        try persist(configured)
        configuration = configured
        endpoint = configured.endpoint
        isConfigured = true
        errorMessage = nil
        await refreshAIStatus()
        return UserSession(
            id: pair.userID?.uuidString ?? normalizedEmail,
            email: pair.email ?? normalizedEmail,
            displayName: pair.displayName
                ?? displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
                ?? normalizedEmail.split(separator: "@").first.map(String.init)
                ?? normalizedEmail,
            provider: .email
        )
    }

    @discardableResult
    func syncNow(items: [ClipboardItem]) async -> Bool {
        guard !isSyncing, var configuration else { return false }
        isSyncing = true
        defer { isSyncing = false }
        errorMessage = nil
        do {
            let records = try items.map { try record(for: $0, deleted: false) }
            for start in stride(from: 0, to: records.count, by: 100) {
                let end = min(start + 100, records.count)
                let response: ServerBatchResponse = try await authorized(
                    path: "/v2/history/items:batch",
                    method: "POST",
                    body: ServerBatch(
                        deviceID: configuration.deviceID,
                        items: Array(records[start..<end])
                    )
                )
                _ = response
            }

            var hasMore = true
            while hasMore {
                let response: ServerChangesResponse = try await authorized(
                    path: "/v2/history/changes?cursor=\(configuration.cursor)&limit=250",
                    method: "GET",
                    body: Optional<String>.none
                )
                for item in response.items {
                    try await apply(item)
                }
                configuration = self.configuration ?? configuration
                configuration.cursor = response.cursor
                self.configuration = configuration
                hasMore = response.hasMore
            }
            lastSyncAt = Date()
            try persist(configuration)
            await refreshAIStatus()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func syncDeletions(_ items: [ClipboardItem]) async {
        guard !items.isEmpty, let configuration else { return }
        do {
            let deletionTime = Date()
            let records = try items.map { original in
                var item = original
                item.updatedAt = deletionTime
                return try record(for: item, deleted: true)
            }
            for start in stride(from: 0, to: records.count, by: 100) {
                let end = min(start + 100, records.count)
                let response: ServerBatchResponse = try await authorized(
                    path: "/v2/history/items:batch",
                    method: "POST",
                    body: ServerBatch(
                        deviceID: configuration.deviceID,
                        items: Array(records[start..<end])
                    )
                )
                _ = response
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func askLLM(query: String, locale: String) async throws -> ServerAIResult {
        guard isConfigured else { throw AIServiceError.storageNotConnected }
        let status: AIStatusResponse = try await authorized(
            path: "/v1/ai/status",
            method: "GET",
            body: Optional<String>.none,
            timeoutInterval: 15
        )
        updateAIStatus(status)
        guard status.available else {
            throw AIServiceError.status(status.detail)
        }
        let response: AISearchResponse = try await authorized(
            path: "/v1/ai/search",
            method: "POST",
            body: AISearchRequest(
                query: String(query.prefix(2_000)),
                locale: locale == "ru" ? "ru" : "en"
            ),
            timeoutInterval: 180
        )
        return ServerAIResult(
            answer: response.answer,
            itemIDs: response.itemIDs,
            model: response.model
        )
    }

    func refreshAIStatus() async {
        guard isConfigured else {
            aiAvailable = false
            aiStatusDetail = "storage_not_connected"
            return
        }
        do {
            let response: AIStatusResponse = try await authorized(
                path: "/v1/ai/status",
                method: "GET",
                body: Optional<String>.none,
                timeoutInterval: 15
            )
            updateAIStatus(response)
        } catch {
            aiAvailable = false
            aiStatusDetail = "gemini_unreachable"
        }
    }

    private func configure(
        session: UserSession,
        password: String,
        register: Bool
    ) {
        guard password.count >= 12 else {
            errorMessage = String(localized: "sync.error.password")
            return
        }
        guard let normalizedEndpoint = normalizedEndpoint(endpoint) else {
            errorMessage = String(localized: "sync.error.endpoint")
            return
        }
        isSyncing = true
        errorMessage = nil
        Task {
            do {
                let deviceID = configuration?.deviceID ?? UUID()
                let pair: TokenPair = try await request(
                    endpoint: normalizedEndpoint,
                    path: register ? "/v1/auth/register" : "/v1/auth/login",
                    method: "POST",
                    body: AuthRequest(
                        email: session.email,
                        password: password,
                        displayName: register ? session.displayName : nil,
                        deviceID: deviceID
                    ),
                    bearer: nil
                )
                let configured = Configuration(
                    endpoint: normalizedEndpoint.absoluteString.trimmingCharacters(
                        in: CharacterSet(charactersIn: "/")
                    ),
                    accessToken: pair.accessToken,
                    refreshToken: pair.refreshToken,
                    deviceID: deviceID,
                    cursor: 0,
                    enabled: true,
                    accountEmail: session.email
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                )
                try persist(configured)
                configuration = configured
                endpoint = configured.endpoint
                isConfigured = true
                isSyncing = false
                onConfigured?()
                await refreshAIStatus()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSyncing = false
        }
    }

    private func record(for item: ClipboardItem, deleted: Bool) throws -> ServerItem {
        var portableItem = item
        let imageData = item.imageData
            ?? item.imagePath.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
        portableItem.imagePath = nil
        portableItem.imageData = nil
        let payload = ServerClipboardPayload(item: portableItem, imageData: imageData)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return ServerItem(
            itemID: item.id,
            revision: Int64(item.updatedAt.timeIntervalSince1970 * 1_000),
            deleted: deleted,
            payload: try encoder.encode(payload)
        )
    }

    private func apply(_ record: ServerItem) async throws {
        if record.deleted {
            try await repository.softDelete(id: record.itemID)
            return
        }
        if let existing = try await repository.item(id: record.itemID) {
            let localRevision = Int64(existing.updatedAt.timeIntervalSince1970 * 1_000)
            guard record.revision > localRevision else { return }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let payload = try decoder.decode(ServerClipboardPayload.self, from: record.payload)
        var item = payload.item
        guard item.id == record.itemID else { throw URLError(.cannotParseResponse) }
        item.imagePath = nil
        item.imageData = payload.imageData
        item.processingStatus = .persisted
        try await repository.save(item, embedding: nil)
    }

    private func updateAIStatus(_ status: AIStatusResponse) {
        aiAvailable = status.available
        aiModel = status.model
        aiProvider = status.provider ?? "google"
        aiStatusDetail = status.detail
    }

    var aiDisplayName: String {
        "\(aiModel.replacingOccurrences(of: "-", with: " ").uppercased()) · API · SERVER"
    }

    private func authorized<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body?,
        timeoutInterval: TimeInterval = 30
    ) async throws -> Response {
        guard var configuration,
              let endpoint = URL(string: configuration.endpoint) else {
            throw URLError(.userAuthenticationRequired)
        }
        do {
            return try await request(
                endpoint: endpoint,
                path: path,
                method: method,
                body: body,
                bearer: configuration.accessToken,
                timeoutInterval: timeoutInterval
            )
        } catch SyncTransportError.unauthorized {
            let pair: TokenPair = try await request(
                endpoint: endpoint,
                path: "/v1/auth/refresh",
                method: "POST",
                body: RefreshRequest(
                    refreshToken: configuration.refreshToken,
                    deviceID: configuration.deviceID
                ),
                bearer: nil
            )
            configuration.accessToken = pair.accessToken
            configuration.refreshToken = pair.refreshToken
            self.configuration = configuration
            try persist(configuration)
            return try await request(
                endpoint: endpoint,
                path: path,
                method: method,
                body: body,
                bearer: pair.accessToken,
                timeoutInterval: timeoutInterval
            )
        }
    }

    private func request<Response: Decodable, Body: Encodable>(
        endpoint: URL,
        path: String,
        method: String,
        body: Body?,
        bearer: String?,
        timeoutInterval: TimeInterval = 30
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: endpoint)?.absoluteURL else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401 { throw SyncTransportError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            let detail = try? JSONDecoder().decode(ErrorResponse.self, from: data).detail
            throw SyncTransportError.server(http.statusCode, detail)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func normalizedEndpoint(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed),
              let host = url.host,
              url.scheme == "https"
                || (url.scheme == "http" && ["localhost", "127.0.0.1"].contains(host))
        else { return nil }
        return url
    }

    private static var managedEndpoint: String {
        let environment = ProcessInfo.processInfo.environment["AI_CLIPBOARD_API_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !environment.isEmpty {
            return environment.trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
        }
        let bundled = (Bundle.main.object(
            forInfoDictionaryKey: "AIClipboardAPIBaseURL"
        ) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !bundled.isEmpty, !bundled.contains("REPLACE") else { return "" }
        return bundled.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func isLocalEndpoint(_ value: String) -> Bool {
        guard let url = URL(string: value), let host = url.host else { return false }
        return ["localhost", "127.0.0.1", "::1"].contains(host)
    }

    private func persist(_ value: Configuration) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(
            to: configurationURL,
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: configurationURL.path
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private enum AIServiceError: LocalizedError {
    case storageNotConnected
    case apiKeyMissing
    case apiKeyInvalid
    case modelUnavailable
    case quotaExhausted
    case serviceUnavailable

    static func status(_ detail: String) -> Self {
        switch detail {
        case "api_key_missing": .apiKeyMissing
        case "api_key_invalid": .apiKeyInvalid
        case "model_unavailable": .modelUnavailable
        case "quota_exhausted": .quotaExhausted
        default: .serviceUnavailable
        }
    }

    var errorDescription: String? {
        switch self {
        case .storageNotConnected: String(localized: "ai.error.storageNotConnected")
        case .apiKeyMissing: String(localized: "ai.error.apiKeyMissing")
        case .apiKeyInvalid: String(localized: "ai.error.apiKeyInvalid")
        case .modelUnavailable: String(localized: "ai.error.modelUnavailable")
        case .quotaExhausted: String(localized: "ai.error.quotaExhausted")
        case .serviceUnavailable: String(localized: "ai.error.geminiUnavailable")
        }
    }
}

private enum SyncTransportError: LocalizedError {
    case unauthorized
    case server(Int, String?)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            String(localized: "sync.error.auth")
        case let .server(_, detail):
            detail.map { "\(String(localized: "sync.error.server")) (\($0))" }
                ?? String(localized: "sync.error.server")
        }
    }
}
