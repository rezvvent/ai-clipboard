import XCTest
@testable import AIClipboardCore

final class ProcessingTests: XCTestCase {
    private let normalizer = TextNormalizer()
    private let detector = ContentDetector()
    private let secrets = SecretDetector()

    func testNormalizationPreservesMeaningAndCanonicalizesWhitespace() {
        let input = "  hello\u{00A0}  world\r\n\r\n\r\nnext\u{200B}  "
        XCTAssertEqual(normalizer.normalize(input), "hello world\n\nnext")
    }

    func testContentTypes() {
        XCTAssertEqual(detector.detect(text: "https://developer.apple.com/documentation/appkit/nspasteboard", hasImage: false, files: []), .url)
        XCTAssertEqual(detector.detect(text: "docker exec -it db psql", hasImage: false, files: []), .terminalCommand)
        XCTAssertEqual(detector.detect(text: #"{"port":5432}"#, hasImage: false, files: []), .json)
        XCTAssertEqual(detector.detect(text: "person@example.com", hasImage: false, files: []), .emailAddress)
        XCTAssertEqual(detector.detect(text: "#ff00aa", hasImage: false, files: []), .color)
        XCTAssertEqual(detector.detect(text: "func hello() {\n print(\"hi\")\n}", hasImage: false, files: []), .code)
        XCTAssertEqual(detector.detect(text: "", hasImage: true, files: []), .image)
        XCTAssertEqual(detector.detect(text: "", hasImage: false, files: [.init(path: "/tmp/a", displayName: "a")]), .file)
    }

    func testSecretDetectionPolicies() {
        XCTAssertEqual(secrets.detect(in: "password = hunter42")?.type, .password)
        XCTAssertEqual(secrets.detect(in: "Your code is not included"), nil)
        XCTAssertEqual(secrets.detect(in: "123 456")?.type, .oneTimeCode)
        XCTAssertEqual(
            secrets.detect(in: "-----BEGIN PRIVATE KEY-----\nnot-a-real-test-key\n-----END PRIVATE KEY-----")?.recommendedPolicy,
            .neverSave
        )
        XCTAssertEqual(secrets.detect(in: "sk-abcdefghijklmnopqrstuvwxyz012345")?.type, .apiKey)
        XCTAssertEqual(secrets.detect(in: "4242 4242 4242 4242")?.type, .paymentCard)
        XCTAssertNil(secrets.detect(in: "https://chatgpt.com/c/example-conversation-identifier"))
    }

    func testQueryParsingInRussian() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let query = QueryParser().parse("найди ссылку, которую копировал вчера в Chrome", now: now, calendar: calendar)
        XCTAssertEqual(query.filters.contentType, .url)
        XCTAssertEqual(query.filters.applicationName, "Chrome")
        XCTAssertNotNil(query.filters.from)
        XCTAssertNotNil(query.filters.to)
        XCTAssertFalse(query.semanticQuery.lowercased().contains("вчера"))
    }

    func testStructuredQueryOperators() {
        let query = QueryParser().parse(
            #"connection type:sql app:"DBeaver" project:marketplace copied:this_week sensitive:false contains:postgres"#
        )
        XCTAssertEqual(query.filters.contentType, .code)
        XCTAssertEqual(query.filters.applicationName, "DBeaver")
        XCTAssertEqual(query.filters.projectName, "marketplace")
        XCTAssertEqual(query.filters.containsText, "postgres")
        XCTAssertEqual(query.filters.sensitivity, false)
        XCTAssertNotNil(query.filters.from)
        XCTAssertFalse(query.semanticQuery.contains("type:"))
    }

    func testQuickTextActionsAndTabularProfiling() {
        let transformer = QuickTextTransformer()
        XCTAssertEqual(transformer.apply(.clean, to: " a   b "), "a b")
        XCTAssertEqual(transformer.apply(.extractURLs, to: "Open https://example.com now"), "https://example.com")

        let profile = TabularProfiler().profile(
            "email,amount\none@example.com,10\none@example.com,10\n,20"
        )
        XCTAssertEqual(profile?.rowCount, 3)
        XCTAssertEqual(profile?.columnCount, 2)
        XCTAssertEqual(profile?.duplicateRowCount, 1)
        XCTAssertEqual(profile?.columns.first?.isPotentialPII, true)
        XCTAssertEqual(profile?.columns.first?.missingCount, 1)
    }

    func testLocalEmbeddingIsStableAndBilingual() async throws {
        let provider = MultilingualLocalEmbeddingProvider()
        let russian = try await provider.embed("как зайти в базу внутри контейнера")
        let english = try await provider.embed("docker exec database")
        let unrelated = try await provider.embed("purple shoes and interview")
        XCTAssertEqual(russian.count, 384)
        XCTAssertGreaterThan(cosineSimilarity(russian, english), cosineSimilarity(russian, unrelated))
    }

    func testRankingPrioritizesExactMatch() {
        let item = ClipboardItem(
            contentType: .plainText,
            rawText: "example",
            normalizedText: "example",
            createdAt: Date(),
            contentHash: "hash"
        )
        let ranker = HybridRanker()
        let exact = ranker.score(item: item, keyword: 1, semantic: 0.1)
        let semantic = ranker.score(item: item, keyword: 0, semantic: 0.9)
        XCTAssertGreaterThan(exact.finalScore, semantic.finalScore)
    }

    func testFileBackedEncryptionUsesRestrictedKeyFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIClipboardKeyTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyURL = directory.appendingPathComponent("protected-content.key")
        let service = try FileBackedEncryptionService(keyURL: keyURL)
        let clear = Data("protected test value".utf8)
        let encrypted = try service.encrypt(clear)

        XCTAssertNotEqual(encrypted, clear)
        XCTAssertEqual(try service.decrypt(encrypted), clear)
        let attributes = try FileManager.default.attributesOfItem(atPath: keyURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testHotKeySettingsPersistAcrossLaunches() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIClipboardSettingsTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsURL = directory.appendingPathComponent("settings.json")

        let first = PrivacySettings(fileURL: settingsURL)
        try await first.setHotKey(keyCode: 11, modifiers: 768, display: "⌘⇧B")
        try await first.markAccountPromptShown()

        let restored = await PrivacySettings(fileURL: settingsURL).current()
        XCTAssertEqual(restored.hotKeyKeyCode, 11)
        XCTAssertEqual(restored.hotKeyModifiers, 768)
        XCTAssertEqual(restored.hotKeyDisplay, "⌘⇧B")
        XCTAssertEqual(restored.accountPromptShown, true)
    }
}
