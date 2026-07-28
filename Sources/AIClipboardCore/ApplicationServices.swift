import Foundation

public actor PrivacySettings: PrivacyChecking {
    public struct Snapshot: Codable, Sendable {
        public var excludedBundleIdentifiers: Set<String> = [
            "com.1password.1password", "com.agilebits.onepassword7", "com.apple.keychainaccess"
        ]
        public var excludedDomains: Set<String>?
        public var disabledTypes: Set<ClipboardContentType> = []
        public var pausedUntil: Date?
        public var sensitivePolicy: SensitivePolicy = .saveEncrypted
        public var monitoringInterval: TimeInterval = 0.75
        public var onboardingCompleted = false
        public var appearanceMode: String?
        public var languageCode: String?
        public var hotKeyKeyCode: UInt32?
        public var hotKeyModifiers: UInt32?
        public var hotKeyDisplay: String?
        public var accountPromptShown: Bool?
        public var duplicateRepairVersion: Int?
        public var autorunPromptVersion: Int?

        public init() {}
    }

    private var snapshot: Snapshot
    private let fileURL: URL?

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode(Snapshot.self, from: data) {
            self.snapshot = loaded
        } else {
            self.snapshot = Snapshot()
        }
    }

    public func current() -> Snapshot { snapshot }

    public func shouldCapture(
        source: SourceApplication?,
        contentType: ClipboardContentType,
        normalizedText: String
    ) -> Bool {
        if let bundle = source?.bundleIdentifier, snapshot.excludedBundleIdentifiers.contains(bundle) { return false }
        if let domain = Self.domain(from: normalizedText),
           (snapshot.excludedDomains ?? []).contains(where: {
               domain == $0 || domain.hasSuffix(".\($0)")
           }) {
            return false
        }
        return !snapshot.disabledTypes.contains(contentType)
    }

    public func isPaused() -> Bool {
        guard let until = snapshot.pausedUntil else { return false }
        return until == .distantFuture || until > Date()
    }

    public func pause(for duration: TimeInterval?) throws {
        snapshot.pausedUntil = duration.map {
            $0.isFinite ? Date().addingTimeInterval($0) : .distantFuture
        } ?? .distantFuture
        try persist()
    }

    public func resume() throws {
        snapshot.pausedUntil = nil
        try persist()
    }

    public func exclude(bundleIdentifier: String) throws {
        snapshot.excludedBundleIdentifiers.insert(bundleIdentifier)
        try persist()
    }

    public func include(bundleIdentifier: String) throws {
        snapshot.excludedBundleIdentifiers.remove(bundleIdentifier)
        try persist()
    }

    public func exclude(domain value: String) throws {
        guard let domain = Self.normalizedDomain(value) else { return }
        var domains = snapshot.excludedDomains ?? []
        domains.insert(domain)
        snapshot.excludedDomains = domains
        try persist()
    }

    public func include(domain value: String) throws {
        guard let domain = Self.normalizedDomain(value) else { return }
        var domains = snapshot.excludedDomains ?? []
        domains.remove(domain)
        snapshot.excludedDomains = domains
        try persist()
    }

    public func completeOnboarding() throws {
        snapshot.onboardingCompleted = true
        try persist()
    }

    public func setAppearanceMode(_ value: String) throws {
        snapshot.appearanceMode = value
        try persist()
    }

    public func setLanguageCode(_ value: String) throws {
        snapshot.languageCode = value
        try persist()
    }

    public func setHotKey(keyCode: UInt32, modifiers: UInt32, display: String) throws {
        snapshot.hotKeyKeyCode = keyCode
        snapshot.hotKeyModifiers = modifiers
        snapshot.hotKeyDisplay = display
        try persist()
    }

    public func markAccountPromptShown() throws {
        snapshot.accountPromptShown = true
        try persist()
    }

    public func markDuplicateRepair(version: Int) throws {
        snapshot.duplicateRepairVersion = version
        try persist()
    }

    public func markAutorunPrompt(version: Int) throws {
        snapshot.autorunPromptVersion = version
        try persist()
    }

    private func persist() throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private static func domain(from value: String) -> String? {
        guard value.contains("://") else { return nil }
        return normalizedDomain(value)
    }

    private static func normalizedDomain(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let host = URL(string: candidate)?.host?
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased(),
            !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

public actor ClipboardProcessingPipeline {
    private let repository: ClipboardRepository
    private let normalizer: TextNormalizing
    private let detector: ContentDetecting
    private let secretDetector: SecretDetecting
    private let embeddingProvider: EmbeddingProviding
    private let privacy: PrivacyChecking
    private let logger: DiagnosticLogging
    private let imageDirectory: URL?
    private let duplicateWindow: TimeInterval
    private let maximumTextBytes: Int
    private let maximumImageBytes: Int
    private let enableEmbeddings: Bool

    public init(
        repository: ClipboardRepository,
        normalizer: TextNormalizing = TextNormalizer(),
        detector: ContentDetecting = ContentDetector(),
        secretDetector: SecretDetecting = SecretDetector(),
        embeddingProvider: EmbeddingProviding = MultilingualLocalEmbeddingProvider(),
        privacy: PrivacyChecking,
        logger: DiagnosticLogging = RedactingLogger(),
        imageDirectory: URL? = nil,
        duplicateWindow: TimeInterval = 24 * 60 * 60,
        maximumTextBytes: Int = 2_000_000,
        maximumImageBytes: Int = 25_000_000,
        enableEmbeddings: Bool = true
    ) {
        self.repository = repository
        self.normalizer = normalizer
        self.detector = detector
        self.secretDetector = secretDetector
        self.embeddingProvider = embeddingProvider
        self.privacy = privacy
        self.logger = logger
        self.imageDirectory = imageDirectory
        self.duplicateWindow = duplicateWindow
        self.maximumTextBytes = maximumTextBytes
        self.maximumImageBytes = maximumImageBytes
        self.enableEmbeddings = enableEmbeddings
    }

    public func process(_ captured: CapturedContent) async -> PipelineOutcome {
        let operationID = UUID()
        do {
            guard !(await privacy.isPaused()) else { return .init(disposition: .excluded) }
            let rawText = captured.plainText ?? captured.fileReferences.map(\.displayName).joined(separator: "\n")
            guard rawText.utf8.count <= maximumTextBytes else {
                logger.error("clipboard_text_oversized", operationID: operationID)
                return .init(disposition: .empty)
            }
            guard captured.imageData?.count ?? 0 <= maximumImageBytes else {
                logger.error("clipboard_image_oversized", operationID: operationID)
                return .init(disposition: .empty)
            }
            let normalized = normalizer.normalize(rawText)
            guard !normalized.isEmpty || captured.imageData != nil || !captured.fileReferences.isEmpty else {
                return .init(disposition: .empty)
            }
            let type = detector.detect(
                text: normalized,
                hasImage: captured.imageData != nil,
                files: captured.fileReferences
            )
            let indexedText = type == .url ? canonicalURLString(normalized) : normalized
            guard await privacy.shouldCapture(
                source: captured.sourceApplication,
                contentType: type,
                normalizedText: indexedText
            ) else {
                return .init(disposition: .excluded)
            }

            // Links are ordinary library items by default. Users can explicitly
            // protect them later; query parameters must not silently move a URL
            // into the protected section.
            let finding = type == .url || indexedText.isEmpty
                ? nil
                : secretDetector.detect(in: indexedText)
            if finding?.recommendedPolicy == .neverSave {
                logger.event("clipboard_rejected_sensitive", fields: ["type": finding!.type.rawValue])
                return .init(disposition: .rejectedSensitive)
            }

            let hashType: ClipboardContentType = type.isTextual ? .plainText : type
            let hash = contentHash(
                hashType,
                normalizedText: type == .image ? "" : indexedText,
                fileReferences: captured.fileReferences,
                binaryContent: captured.imageData
            )
            let duplicateSince: Date = (type.isTextual || type == .image)
                ? .distantPast
                : captured.capturedAt.addingTimeInterval(-duplicateWindow)
            if let duplicate = try await repository.duplicate(hash: hash, since: duplicateSince) {
                try await repository.recordReuse(id: duplicate.id, at: captured.capturedAt)
                logger.event("clipboard_deduplicated", fields: ["type": type.rawValue])
                return .init(disposition: .deduplicated, itemID: duplicate.id)
            }

            let imagePath = try storeImageIfNeeded(captured.imageData, hash: hash)
            let sensitive = finding != nil
            var item = ClipboardItem(
                contentType: type,
                rawText: normalized.isEmpty ? nil : rawText,
                normalizedText: indexedText.isEmpty ? nil : indexedText,
                richTextData: captured.richText,
                imagePath: imagePath,
                imageData: captured.imageData,
                fileReferences: captured.fileReferences,
                sourceApplication: captured.sourceApplication,
                sourceWindowTitle: captured.sourceWindowTitle,
                sourceURL: type == .url ? indexedText : nil,
                createdAt: captured.capturedAt,
                updatedAt: captured.capturedAt,
                isSensitive: sensitive,
                sensitivityType: finding?.type,
                retentionPolicy: finding?.recommendedPolicy == .saveFor5Minutes ? .oneDay : .forever,
                contentHash: hash,
                language: language(of: indexedText),
                title: makeTitle(text: indexedText, type: type, files: captured.fileReferences),
                summary: nil,
                processingStatus: .persisted
            )

            // Repository insertion precedes optional enrichment. The desktop
            // repository is volatile; durable storage is the encrypted server.
            try await repository.save(item, embedding: nil)
            if enableEmbeddings, !sensitive, !indexedText.isEmpty {
                do {
                    let embeddingText = [
                        item.title, item.normalizedText, type.rawValue,
                        item.sourceApplication?.applicationName
                    ].compactMap { $0 }.joined(separator: "\n")
                    let vector = try await embeddingProvider.embed(embeddingText)
                    try await repository.updateEmbedding(id: item.id, embedding: vector)
                    item.processingStatus = .indexed
                } catch {
                    logger.error("embedding_failed", operationID: operationID)
                }
            }
            logger.event("clipboard_stored", fields: ["type": type.rawValue, "sensitive": String(sensitive)])
            return .init(disposition: .stored, itemID: item.id)
        } catch {
            logger.error("pipeline_failed", operationID: operationID)
            return .init(disposition: .empty)
        }
    }

    private func storeImageIfNeeded(_ data: Data?, hash: String) throws -> String? {
        guard let data, let imageDirectory else { return nil }
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        let destination = imageDirectory.appendingPathComponent("\(hash).png")
        if !FileManager.default.fileExists(atPath: destination.path) {
            try data.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
        }
        return destination.path
    }

    private func makeTitle(text: String, type: ClipboardContentType, files: [FileReference]) -> String {
        if let file = files.first { return files.count == 1 ? file.displayName : "\(files.count) files" }
        if type == .url, let host = URL(string: text)?.host { return host }
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? type.displayName
        return String(firstLine.prefix(80))
    }

    private func language(of text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let cyrillic = text.unicodeScalars.filter { (0x0400...0x04FF).contains(Int($0.value)) }.count
        let latin = text.unicodeScalars.filter { (0x0041...0x007A).contains(Int($0.value)) }.count
        if cyrillic > latin / 3 { return "ru" }
        return latin > 0 ? "en" : nil
    }
}

private extension ClipboardContentType {
    var isTextual: Bool {
        switch self {
        case .plainText, .richText, .url, .code, .terminalCommand, .emailAddress,
             .phoneNumber, .address, .color, .json, .xml, .markdown:
            true
        case .image, .file, .fileList, .unknown:
            false
        }
    }
}

public actor SearchService {
    private let repository: ClipboardRepository
    private let embeddingProvider: EmbeddingProviding
    private let parser: QueryParser
    private let ranker: HybridRanker

    public init(
        repository: ClipboardRepository,
        embeddingProvider: EmbeddingProviding = MultilingualLocalEmbeddingProvider(),
        parser: QueryParser = QueryParser(),
        ranker: HybridRanker = HybridRanker()
    ) {
        self.repository = repository
        self.embeddingProvider = embeddingProvider
        self.parser = parser
        self.ranker = ranker
    }

    public func search(_ text: String, filters: SearchFilters = .init(), limit: Int = 50) async throws -> [SearchResult] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return try await repository.recent(limit: limit, filters: filters)
                .map { ranker.score(item: $0, keyword: 0, semantic: 0) }
        }
        var query = parser.parse(text)
        query.limit = limit
        query.filters = merge(query.filters, filters)

        let keywordRows = try await repository.keywordSearch(query)
        let queryVector = try? await embeddingProvider.embed(query.semanticQuery)
        let semanticRows = queryVector == nil
            ? []
            : try await repository.allEmbeddings(filters: query.filters, limit: 10_000)

        var combined: [UUID: (ClipboardItem, Double, Double, String?)] = [:]
        for (item, score, fragment) in keywordRows {
            combined[item.id] = (item, score, 0, fragment)
        }
        for (item, vector) in semanticRows {
            guard let queryVector else { continue }
            let score = cosineSimilarity(queryVector, vector)
            let current = combined[item.id]
            combined[item.id] = (item, current?.1 ?? 0, score, current?.3)
        }
        return combined.values
            .map {
                var result = ranker.score(item: $0.0, keyword: $0.1, semantic: $0.2)
                result.matchedFragment = $0.3
                return result
            }
            .sorted { $0.finalScore > $1.finalScore }
            .prefix(limit)
            .map { $0 }
    }

    private func merge(_ parsed: SearchFilters, _ explicit: SearchFilters) -> SearchFilters {
        SearchFilters(
            from: explicit.from ?? parsed.from,
            to: explicit.to ?? parsed.to,
            applicationName: explicit.applicationName ?? parsed.applicationName,
            contentType: explicit.contentType ?? parsed.contentType,
            pinnedOnly: explicit.pinnedOnly || parsed.pinnedOnly,
            sensitiveOnly: explicit.sensitiveOnly || parsed.sensitiveOnly
        )
    }
}

public struct DataExporter: Sendable {
    public init() {}

    public func json(items: [ClipboardItem], includeSensitive: Bool = false) throws -> Data {
        let filtered = includeSensitive ? items : items.filter { !$0.isSensitive }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(filtered)
    }

    public func csv(items: [ClipboardItem]) -> Data {
        let header = "id,type,title,created_at,source_application,is_pinned,is_favorite\n"
        let rows = items.filter { !$0.isSensitive }.map {
            [
                $0.id.uuidString, $0.contentType.rawValue, $0.title ?? "",
                ISO8601DateFormatter().string(from: $0.createdAt),
                $0.sourceApplication?.applicationName ?? "",
                String($0.isPinned), String($0.isFavorite)
            ].map(csvEscape).joined(separator: ",")
        }.joined(separator: "\n")
        return Data((header + rows + "\n").utf8)
    }

    private func csvEscape(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
