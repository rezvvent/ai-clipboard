import Foundation
import XCTest
@testable import AIClipboardCore

final class RepositoryAndPipelineTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIClipboardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testMigrationPersistenceFTSAndDeletion() async throws {
        let path = temporaryDirectory.appendingPathComponent("history.sqlite").path
        let repository = try SQLiteClipboardRepository(path: path, cipher: TestCipher())
        let item = ClipboardItem(
            contentType: .terminalCommand,
            rawText: "uvicorn app.main:app --reload --port 8001",
            normalizedText: "uvicorn app.main:app --reload --port 8001",
            sourceApplication: .init(bundleIdentifier: "com.apple.Terminal", applicationName: "Terminal"),
            contentHash: "hash",
            title: "Run FastAPI",
            processingStatus: .indexed
        )
        try await repository.save(item, embedding: [1, 0, 0])

        let integrity = try await repository.integrityCheck()
        let recent = try await repository.recent(limit: 10, filters: .init())
        XCTAssertTrue(integrity)
        XCTAssertEqual(recent.count, 1)
        let rows = try await repository.keywordSearch(.init(rawQuery: "uvicorn"))
        XCTAssertEqual(rows.first?.0.id, item.id)
        let embeddings = try await repository.allEmbeddings(filters: .init(), limit: 10)
        XCTAssertFalse(embeddings.isEmpty)

        try await repository.softDelete(id: item.id)
        let afterDelete = try await repository.recent(limit: 10, filters: .init())
        XCTAssertTrue(afterDelete.isEmpty)
        try await repository.emptyTrash()
        let purged = try await repository.item(id: item.id)
        XCTAssertNil(purged)
    }

    func testProtectedItemIsEncryptedAndNotFullTextIndexed() async throws {
        let path = temporaryDirectory.appendingPathComponent("protected.sqlite").path
        let repository = try SQLiteClipboardRepository(path: path, cipher: TestCipher())
        let item = ClipboardItem(
            contentType: .plainText,
            rawText: "sensitive test phrase",
            normalizedText: "sensitive test phrase",
            isSensitive: true,
            sensitivityType: .apiKey,
            contentHash: "protected-hash"
        )
        try await repository.save(item, embedding: nil)
        let stored = try await repository.item(id: item.id)
        let protectedSearch = try await repository.keywordSearch(.init(rawQuery: "sensitive"))
        XCTAssertEqual(stored?.rawText, "sensitive test phrase")
        XCTAssertTrue(protectedSearch.isEmpty)

        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertNil(String(data: bytes, encoding: .utf8)?.range(of: "sensitive test phrase"))
    }

    func testPipelineStoresDeduplicatesAndRejectsOTP() async throws {
        let repository = try SQLiteClipboardRepository(
            path: temporaryDirectory.appendingPathComponent("pipeline.sqlite").path,
            cipher: TestCipher()
        )
        let privacy = PrivacySettings()
        let pipeline = ClipboardProcessingPipeline(
            repository: repository,
            privacy: privacy,
            imageDirectory: temporaryDirectory.appendingPathComponent("Objects")
        )
        let source = SourceApplication(bundleIdentifier: "com.apple.Terminal", applicationName: "Terminal")
        let captured = CapturedContent(
            plainText: "docker exec -it mini_amazon_postgres psql -U postgres -d mini_amazon",
            sourceApplication: source
        )
        let first = await pipeline.process(captured)
        let second = await pipeline.process(captured)
        let otp = await pipeline.process(.init(plainText: "123456", sourceApplication: source))

        XCTAssertEqual(first.disposition, .stored)
        XCTAssertEqual(second.disposition, .deduplicated)
        XCTAssertEqual(otp.disposition, .rejectedSensitive)
        let items = try await repository.recent(limit: 10, filters: .init())
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.usageCount, 2)
    }

    func testHybridSearchFindsMeaningWithoutExactWords() async throws {
        let repository = try SQLiteClipboardRepository(
            path: temporaryDirectory.appendingPathComponent("search.sqlite").path,
            cipher: TestCipher()
        )
        let privacy = PrivacySettings()
        let embeddings = MultilingualLocalEmbeddingProvider()
        let pipeline = ClipboardProcessingPipeline(
            repository: repository,
            embeddingProvider: embeddings,
            privacy: privacy
        )
        _ = await pipeline.process(.init(
            plainText: "docker exec -it mini_amazon_postgres psql -U postgres -d mini_amazon"
        ))
        _ = await pipeline.process(.init(plainText: "Rick Owens DRKSHDW Jumbo Lace Low"))
        let service = SearchService(repository: repository, embeddingProvider: embeddings)
        let result = try await service.search("как зайти в базу внутри контейнера")
        XCTAssertTrue(result.first?.item.rawText?.contains("docker exec") == true)
    }

    func testExcludedApplicationIsNotCaptured() async throws {
        let repository = try SQLiteClipboardRepository(
            path: temporaryDirectory.appendingPathComponent("privacy.sqlite").path,
            cipher: TestCipher()
        )
        let privacy = PrivacySettings()
        try await privacy.exclude(bundleIdentifier: "com.example.private")
        let pipeline = ClipboardProcessingPipeline(repository: repository, privacy: privacy)
        let outcome = await pipeline.process(.init(
            plainText: "ordinary non-secret text",
            sourceApplication: .init(bundleIdentifier: "com.example.private", applicationName: "Private")
        ))
        XCTAssertEqual(outcome.disposition, .excluded)
        let remaining = try await repository.recent(limit: 10, filters: .init())
        XCTAssertTrue(remaining.isEmpty)
    }

    func testExcludedDomainIsNotCaptured() async throws {
        let repository = try SQLiteClipboardRepository(
            path: temporaryDirectory.appendingPathComponent("domain-privacy.sqlite").path,
            cipher: TestCipher()
        )
        let privacy = PrivacySettings()
        try await privacy.exclude(domain: "private.example.com")
        let pipeline = ClipboardProcessingPipeline(repository: repository, privacy: privacy)

        let blocked = await pipeline.process(.init(
            plainText: "https://private.example.com/account"
        ))
        let allowed = await pipeline.process(.init(
            plainText: "https://public.example.com/account"
        ))

        XCTAssertEqual(blocked.disposition, .excluded)
        XCTAssertEqual(allowed.disposition, .stored)
    }

    func testPauseAndResumeActuallyControlCapture() async throws {
        let repository = try SQLiteClipboardRepository(
            path: temporaryDirectory.appendingPathComponent("pause.sqlite").path,
            cipher: TestCipher()
        )
        let privacy = PrivacySettings()
        let pipeline = ClipboardProcessingPipeline(repository: repository, privacy: privacy)

        try await privacy.pause(for: 60 * 60)
        let paused = await pipeline.process(.init(plainText: "not saved while paused"))
        try await privacy.resume()
        let resumed = await pipeline.process(.init(plainText: "saved after resume"))

        XCTAssertEqual(paused.disposition, .excluded)
        XCTAssertEqual(resumed.disposition, .stored)
        let stored = try await repository.recent(limit: 10, filters: .init())
        XCTAssertEqual(stored.count, 1)
    }

    func testURLsDeduplicateBeyondTheNormalTimeWindow() async throws {
        let repository = try SQLiteClipboardRepository(
            path: temporaryDirectory.appendingPathComponent("url-dedup.sqlite").path,
            cipher: TestCipher()
        )
        let pipeline = ClipboardProcessingPipeline(
            repository: repository,
            privacy: PrivacySettings()
        )
        let oldDate = Date().addingTimeInterval(-60 * 24 * 60 * 60)
        let first = await pipeline.process(.init(
            plainText: "HTTPS://WWW.Example.com/",
            capturedAt: oldDate
        ))
        let duplicate = await pipeline.process(.init(
            plainText: "https://example.com"
        ))

        XCTAssertEqual(first.disposition, .stored)
        XCTAssertEqual(duplicate.disposition, .deduplicated)
        let stored = try await repository.recent(limit: 10, filters: .init())
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.normalizedText, "https://example.com")
    }

    func testOneTokenLikeURLCopiedThreeTimesIsOneUnprotectedItem() async throws {
        let repository = InMemoryClipboardRepository()
        let pipeline = ClipboardProcessingPipeline(
            repository: repository,
            privacy: PrivacySettings()
        )
        let link = "https://example.com/reset?token=ghp_1234567890abcdefghijklmnopqrstuvwxyz"

        let first = await pipeline.process(.init(plainText: link))
        let second = await pipeline.process(.init(plainText: link))
        let third = await pipeline.process(.init(plainText: link))
        let stored = try await repository.recent(limit: 10, filters: .init())

        XCTAssertEqual(first.disposition, .stored)
        XCTAssertEqual(second.disposition, .deduplicated)
        XCTAssertEqual(third.disposition, .deduplicated)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.contentType, .url)
        XCTAssertEqual(stored.first?.isSensitive, false)
        XCTAssertNil(stored.first?.sensitivityType)
        XCTAssertEqual(stored.first?.usageCount, 3)
    }

    func testOneTextCopiedThreeTimesIsOneItemInMemory() async throws {
        let repository = InMemoryClipboardRepository()
        let pipeline = ClipboardProcessingPipeline(
            repository: repository,
            privacy: PrivacySettings()
        )

        _ = await pipeline.process(.init(plainText: "One logical clipboard text"))
        _ = await pipeline.process(.init(plainText: "One  logical clipboard text"))
        _ = await pipeline.process(.init(plainText: "One logical clipboard text"))
        let stored = try await repository.recent(limit: 10, filters: .init())

        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.usageCount, 3)
    }

    func testTextDeduplicatesPermanentlyAfterNormalization() async throws {
        let repository = try SQLiteClipboardRepository(
            path: temporaryDirectory.appendingPathComponent("text-dedup.sqlite").path,
            cipher: TestCipher()
        )
        let pipeline = ClipboardProcessingPipeline(
            repository: repository,
            privacy: PrivacySettings()
        )
        let oldDate = Date().addingTimeInterval(-180 * 24 * 60 * 60)
        let first = await pipeline.process(.init(
            plainText: "ordinary text that must exist only once",
            capturedAt: oldDate
        ))
        let duplicate = await pipeline.process(.init(
            plainText: "ordinary   text that must exist only once",
            capturedAt: Date()
        ))

        XCTAssertEqual(first.disposition, .stored)
        XCTAssertEqual(duplicate.disposition, .deduplicated)
        let stored = try await repository.recent(limit: 10, filters: .init())
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.usageCount, 2)
    }

    func testDifferentImagesAreNotDeduplicated() async throws {
        let repository = try SQLiteClipboardRepository(
            path: temporaryDirectory.appendingPathComponent("images.sqlite").path,
            cipher: TestCipher()
        )
        let pipeline = ClipboardProcessingPipeline(
            repository: repository,
            privacy: PrivacySettings(),
            imageDirectory: temporaryDirectory.appendingPathComponent("Objects")
        )

        let first = await pipeline.process(.init(imageData: Data([0x01, 0x02, 0x03])))
        let second = await pipeline.process(.init(imageData: Data([0x04, 0x05, 0x06])))
        let duplicate = await pipeline.process(.init(
            plainText: "A different textual pasteboard representation",
            imageData: Data([0x01, 0x02, 0x03])
        ))
        let stored = try await repository.recent(limit: 10, filters: .init())

        XCTAssertEqual(first.disposition, .stored)
        XCTAssertEqual(second.disposition, .stored)
        XCTAssertEqual(duplicate.disposition, .deduplicated)
        XCTAssertEqual(stored.count, 2)
    }

    func testClearingSensitivityRestoresFullTextIndex() async throws {
        let repository = try SQLiteClipboardRepository(
            path: temporaryDirectory.appendingPathComponent("sensitivity.sqlite").path,
            cipher: TestCipher()
        )
        let item = ClipboardItem(
            contentType: .url,
            rawText: "https://example.com/ordinary-page",
            normalizedText: "https://example.com/ordinary-page",
            sourceURL: "https://example.com/ordinary-page",
            isSensitive: true,
            sensitivityType: .accessToken,
            contentHash: "legacy-url"
        )
        try await repository.save(item, embedding: nil)
        try await repository.setSensitivity(id: item.id, isSensitive: false, type: nil)

        let restored = try await repository.item(id: item.id)
        let results = try await repository.keywordSearch(.init(rawQuery: "ordinary"))
        XCTAssertEqual(restored?.isSensitive, false)
        XCTAssertEqual(results.first?.0.id, item.id)

        try await repository.setSensitivity(id: item.id, isSensitive: true, type: .personalData)
        let protectedResults = try await repository.keywordSearch(.init(rawQuery: "ordinary"))
        let protectedItem = try await repository.item(id: item.id)
        XCTAssertTrue(protectedResults.isEmpty)
        XCTAssertEqual(protectedItem?.rawText, item.rawText)

        try await repository.setSensitivity(id: item.id, isSensitive: false, type: nil)
        let unprotectedResults = try await repository.keywordSearch(.init(rawQuery: "ordinary"))
        XCTAssertEqual(
            unprotectedResults.first?.0.id,
            item.id
        )
    }

    func testMergingDuplicatePreservesUsefulMetadata() async throws {
        let repository = try SQLiteClipboardRepository(
            path: temporaryDirectory.appendingPathComponent("merge.sqlite").path,
            cipher: TestCipher()
        )
        let keeper = ClipboardItem(
            contentType: .url,
            rawText: "https://example.com",
            normalizedText: "https://example.com",
            sourceURL: "https://example.com",
            usageCount: 2,
            isPinned: false,
            contentHash: "same"
        )
        var duplicate = keeper
        duplicate.id = UUID()
        duplicate.usageCount = 3
        duplicate.isPinned = true
        duplicate.isFavorite = true
        try await repository.save(keeper, embedding: nil)
        try await repository.save(duplicate, embedding: nil)

        try await repository.mergeDuplicate(keeping: keeper.id, removing: duplicate.id)

        let merged = try await repository.item(id: keeper.id)
        XCTAssertEqual(merged?.usageCount, 5)
        XCTAssertEqual(merged?.isPinned, true)
        XCTAssertEqual(merged?.isFavorite, true)
        let removed = try await repository.item(id: duplicate.id)
        XCTAssertNil(removed)
    }

    func testInMemoryMergeNeverUnlocksProtectedDuplicate() async throws {
        let repository = InMemoryClipboardRepository()
        let keeper = ClipboardItem(
            contentType: .url,
            rawText: "https://example.com/private",
            normalizedText: "https://example.com/private",
            sourceURL: "https://example.com/private",
            contentHash: "same-private-url"
        )
        var protectedDuplicate = keeper
        protectedDuplicate.id = UUID()
        protectedDuplicate.isSensitive = true
        protectedDuplicate.sensitivityType = .personalData
        try await repository.save(keeper, embedding: [1, 0, 0])
        try await repository.save(protectedDuplicate, embedding: nil)

        try await repository.mergeDuplicate(
            keeping: keeper.id,
            removing: protectedDuplicate.id
        )

        let merged = try await repository.item(id: keeper.id)
        XCTAssertEqual(merged?.isSensitive, true)
        XCTAssertEqual(merged?.sensitivityType, .personalData)
        let searchable = try await repository.keywordSearch(
            .init(rawQuery: "private")
        )
        XCTAssertTrue(searchable.isEmpty)
    }

    func testSQLiteMergeNeverUnlocksProtectedDuplicate() async throws {
        let repository = try SQLiteClipboardRepository(
            path: temporaryDirectory.appendingPathComponent("protected-merge.sqlite").path,
            cipher: TestCipher()
        )
        let keeper = ClipboardItem(
            contentType: .url,
            rawText: "https://example.com/private",
            normalizedText: "https://example.com/private",
            sourceURL: "https://example.com/private",
            contentHash: "same-private-url"
        )
        var protectedDuplicate = keeper
        protectedDuplicate.id = UUID()
        protectedDuplicate.isSensitive = true
        protectedDuplicate.sensitivityType = .personalData
        try await repository.save(keeper, embedding: [1, 0, 0])
        try await repository.save(protectedDuplicate, embedding: nil)

        try await repository.mergeDuplicate(
            keeping: keeper.id,
            removing: protectedDuplicate.id
        )

        let merged = try await repository.item(id: keeper.id)
        XCTAssertEqual(merged?.isSensitive, true)
        XCTAssertEqual(merged?.sensitivityType, .personalData)
        let searchable = try await repository.keywordSearch(
            .init(rawQuery: "private")
        )
        XCTAssertTrue(searchable.isEmpty)
    }
}

private struct TestCipher: ContentEncrypting {
    func encrypt(_ data: Data) throws -> Data { Data(data.map { $0 ^ 0xA5 }) }
    func decrypt(_ data: Data) throws -> Data { Data(data.map { $0 ^ 0xA5 }) }
}
