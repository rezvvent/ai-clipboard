import AIClipboardCore
import AppKit
import Carbon
import Combine
import Foundation
import LocalAuthentication
import SwiftUI

struct AIRecallAnswer {
    var text: String
    var results: [SearchResult]
    var model: String
}

enum FirstLaunchPolicy {
    static func shouldPresentAutorun(version: Int?, isSnapshotRun: Bool) -> Bool {
        !isSnapshotRun && (version ?? 0) < 3
    }
}

enum LocalClipboardDataPurger {
    static func purge(in supportDirectory: URL) {
        let manager = FileManager.default
        let exactFiles = [
            "AIClipboard.sqlite",
            "AIClipboard.sqlite-wal",
            "AIClipboard.sqlite-shm",
            "protected-content.key",
            "sync-master.key"
        ]
        for filename in exactFiles {
            let url = supportDirectory.appendingPathComponent(filename)
            if manager.fileExists(atPath: url.path) {
                try? manager.removeItem(at: url)
            }
        }
        let objects = supportDirectory.appendingPathComponent("Objects", isDirectory: true)
        if manager.fileExists(atPath: objects.path) {
            try? manager.removeItem(at: objects)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var items: [ClipboardItem] = []
    @Published var searchResults: [SearchResult] = []
    @Published var query = ""
    @Published var selectedItemID: UUID?
    @Published var isPaused = false
    @Published var onboardingCompleted = true
    @Published var autorunPromptPresented = false
    @Published var errorMessage: String?
    @Published var selectedSection: LibrarySection = .all
    @Published var appearanceMode = "system"
    @Published var languageCode = Locale.current.language.languageCode?.identifier == "ru" ? "ru" : "en"
    @Published var experienceMode: ExperienceMode = .basic
    @Published var hotKeyKeyCode = UInt32(kVK_ANSI_V)
    @Published var hotKeyModifiers = UInt32(cmdKey | shiftKey)
    @Published var hotKeyDisplay = "⌘⇧V"

    let repository: InMemoryClipboardRepository
    let privacy: PrivacySettings
    let pipeline: ClipboardProcessingPipeline
    let searchService: SearchService
    let accountStore: AccountStore
    let subscriptionManager: SubscriptionManager
    let syncCoordinator: SecureSyncCoordinator
    let launchAtLoginController = LaunchAtLoginController()
    let clipboardMonitor: ClipboardMonitor
    let pasteController = PasteController()
    private var hotKey: GlobalHotKey?
    private var quickSearchPanel: QuickSearchPanelController?
    private var settingsWindow: SettingsWindowController?
    private var accountWindow: AccountWindowController?
    private var searchTask: Task<Void, Never>?
    private var pauseStatusTask: Task<Void, Never>?
    private var hasStarted = false
    private var activeAccountID: String?

    init() throws {
        let support = try Self.applicationSupportDirectory()
        LocalClipboardDataPurger.purge(in: support)
        repository = InMemoryClipboardRepository()
        privacy = PrivacySettings(fileURL: support.appendingPathComponent("settings.json"))
        let embeddings = ServerOnlyEmbeddingProvider()
        pipeline = ClipboardProcessingPipeline(
            repository: repository,
            embeddingProvider: embeddings,
            privacy: privacy,
            imageDirectory: nil,
            enableEmbeddings: false
        )
        searchService = SearchService(repository: repository, embeddingProvider: embeddings)
        accountStore = try AccountStore(directory: support)
        subscriptionManager = SubscriptionManager()
        syncCoordinator = try SecureSyncCoordinator(
            directory: support,
            repository: repository
        )
        clipboardMonitor = ClipboardMonitor(pipeline: pipeline)
        pasteController.onPasteboardWrite = { [weak clipboardMonitor] changeCount in
            clipboardMonitor?.ignorePasteboardChange(changeCount)
        }
        activeAccountID = accountStore.session?.id
        syncCoordinator.activateAccount(email: accountStore.session?.email)
        accountStore.onSessionChanged = { [weak self] session in
            self?.handleAccountChange(session)
        }
        accountStore.emailAuthenticator = { [weak syncCoordinator] email, password, name, register in
            guard let syncCoordinator else {
                throw AccountError.network("server_unavailable")
            }
            return try await syncCoordinator.authenticateEmail(
                email: email,
                password: password,
                displayName: name,
                register: register
            )
        }
        syncCoordinator.onConfigured = { [weak self] in
            Task {
                guard let self else { return }
                await self.syncServerHistory()
            }
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        clipboardMonitor.onProcessedChange = { [weak self] _ in
            Task {
                guard let self else { return }
                await self.refresh()
                if self.syncCoordinator.isConfigured {
                    // A failed upload remains in volatile process memory and is
                    // retried by the next capture or a manual sync. Clipboard
                    // contents are never written to the Mac's disk.
                    await self.syncServerHistory()
                }
            }
        }
        Task {
            let settings = await privacy.current()
            let environment = ProcessInfo.processInfo.environment
            let isAutorunSnapshot = environment["AI_CLIPBOARD_SNAPSHOT_SCREEN"] == "autorun"
            let isSnapshotRun = environment["AI_CLIPBOARD_SNAPSHOT_PATH"] != nil
                && !isAutorunSnapshot
            let shouldPresentAutorun = FirstLaunchPolicy.shouldPresentAutorun(
                version: settings.autorunPromptVersion,
                isSnapshotRun: isSnapshotRun
            )
            autorunPromptPresented = shouldPresentAutorun
            isPaused = await privacy.isPaused()
            schedulePauseStatusRefresh(until: settings.pausedUntil)
            onboardingCompleted = isSnapshotRun ? true : settings.onboardingCompleted
            appearanceMode = settings.appearanceMode ?? "system"
            languageCode = settings.languageCode ?? languageCode
            experienceMode = settings.experienceMode ?? .basic
            let configuredKeyCode = settings.hotKeyKeyCode ?? UInt32(kVK_ANSI_V)
            let configuredModifiers = settings.hotKeyModifiers ?? UInt32(cmdKey | shiftKey)
            let configuredDisplay = settings.hotKeyDisplay ?? "⌘⇧V"
            installHotKey(
                keyCode: configuredKeyCode,
                modifiers: configuredModifiers,
                display: configuredDisplay,
                persist: false
            )
            // Capture starts immediately. Before server setup, history exists
            // only in volatile RAM and is uploaded as soon as storage connects.
            clipboardMonitor.start(interval: settings.monitoringInterval)
            if ProcessInfo.processInfo.arguments.contains("--seed") {
                await seedDevelopmentData()
            }
            await refresh()
            await syncServerHistory()
            await refresh()
            if !isSnapshotRun, !shouldPresentAutorun, settings.onboardingCompleted {
                presentAccountPromptIfNeeded(settings)
            }
        }
        quickSearchPanel = QuickSearchPanelController(model: self)
        settingsWindow = SettingsWindowController(model: self)
        accountWindow = AccountWindowController(model: self)
    }

    func showQuickSearch() {
        pasteController.rememberFrontmostApplication()
        query = ""
        searchResults = []
        selectedItemID = nil
        quickSearchPanel?.show()
    }

    func closeQuickSearch() {
        quickSearchPanel?.dismiss()
    }

    func showSettings() {
        settingsWindow?.show()
    }

    func showAccount() {
        accountWindow?.show()
    }

    func refresh() async {
        do {
            items = try await repository.recent(limit: 10_000, filters: .init())
            if query.isEmpty {
                searchResults = sectionItems(from: items).map {
                    HybridRanker().score(item: $0, keyword: 0, semantic: 0)
                }
            }
        } catch {
            errorMessage = String(localized: "storage.error")
        }
    }

    @discardableResult
    func syncServerHistory() async -> Bool {
        let uniqueUpload = deduplicatedForMigration(items)
        guard await syncCoordinator.syncNow(items: uniqueUpload) else { return false }

        await normalizeRemoteHistory()
        await refresh()
        return true
    }

    func scheduleSearch() {
        searchTask?.cancel()
        let current = query
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            do {
                let found = try await searchService.search(current, filters: filters(for: selectedSection))
                guard !Task.isCancelled else { return }
                let filtered = found.filter { matches($0.item, section: selectedSection) }
                searchResults = filtered
                if !filtered.contains(where: { $0.id == selectedItemID }) {
                    selectedItemID = filtered.first?.id
                }
            } catch {
                errorMessage = String(localized: "search.error")
            }
        }
    }

    func askAI(_ prompt: String) async throws -> AIRecallAnswer {
        let response = try await syncCoordinator.askLLM(
            query: prompt,
            locale: languageCode
        )
        let byID = Dictionary(uniqueKeysWithValues: items.map {
            ($0.id, HybridRanker().score(item: $0, keyword: 0, semantic: 1))
        })
        return AIRecallAnswer(
            text: response.answer,
            results: response.itemIDs.compactMap { byID[$0] },
            model: response.model
        )
    }

    func paste(_ item: ClipboardItem, plainText: Bool = false) {
        Task {
            do {
                pasteController.copy(item, plainText: plainText)
                try await repository.recordReuse(id: item.id, at: Date())
                closeQuickSearch()
                pasteController.restoreFocus()
                await refresh()
                await syncServerHistory()
            } catch {
                errorMessage = String(localized: "paste.error")
            }
        }
    }

    func togglePin(_ item: ClipboardItem) {
        Task {
            try? await repository.setPinned(id: item.id, value: !item.isPinned)
            await refresh()
            await syncServerHistory()
        }
    }

    func toggleFavorite(_ item: ClipboardItem) {
        Task {
            try? await repository.setFavorite(id: item.id, value: !item.isFavorite)
            await refresh()
            await syncServerHistory()
        }
    }

    func delete(_ item: ClipboardItem) {
        Task {
            try? await repository.softDelete(id: item.id)
            await syncCoordinator.syncDeletions([item])
            selectedItemID = nil
            await refresh()
        }
    }

    func setPause(_ duration: TimeInterval?) {
        Task {
            do {
                if let duration { try await privacy.pause(for: duration) }
                else { try await privacy.resume() }
                isPaused = await privacy.isPaused()
                let settings = await privacy.current()
                schedulePauseStatusRefresh(until: settings.pausedUntil)
            } catch {
                errorMessage = String(localized: "settings.error")
            }
        }
    }

    func excludeCurrentSource(_ item: ClipboardItem) {
        guard let bundle = item.sourceApplication?.bundleIdentifier else { return }
        Task {
            try? await privacy.exclude(bundleIdentifier: bundle)
        }
    }

    func setProtected(_ item: ClipboardItem, value: Bool) {
        Task {
            do {
                try await repository.setSensitivity(
                    id: item.id,
                    isSensitive: value,
                    type: value ? .personalData : nil
                )
                if value, selectedSection != .protected {
                    selectedItemID = nil
                }
                await refresh()
                await syncServerHistory()
            } catch {
                errorMessage = String(localized: "storage.error")
            }
        }
    }

    func completeOnboarding() {
        Task {
            try? await privacy.completeOnboarding()
            onboardingCompleted = true
            let settings = await privacy.current()
            presentAccountPromptIfNeeded(settings)
        }
    }

    func finishAutorunPrompt(enable: Bool, openSettings: Bool = false) {
        if enable {
            switch launchAtLoginController.setEnabled(true) {
            case .enabled:
                autorunPromptPresented = false
            case .requiresApproval:
                autorunPromptPresented = false
                launchAtLoginController.openSystemSettings()
            case .failed, .disabled:
                // Keep the modal open so the concrete registration error is visible.
                return
            }
        } else {
            autorunPromptPresented = false
        }
        if openSettings {
            launchAtLoginController.openSystemSettings()
        }
        Task {
            try? await privacy.markAutorunPrompt(version: 3)
            let settings = await privacy.current()
            if settings.onboardingCompleted {
                presentAccountPromptIfNeeded(settings)
            }
        }
    }

    func setAppearanceMode(_ value: String) {
        appearanceMode = value
        Task { try? await privacy.setAppearanceMode(value) }
    }

    func setLanguageCode(_ value: String) {
        languageCode = value
        Task { try? await privacy.setLanguageCode(value) }
    }

    func setExperienceMode(_ value: String) {
        guard let mode = ExperienceMode(rawValue: value) else { return }
        experienceMode = mode
        if !visibleSections.contains(selectedSection) {
            selectSection(.all)
        }
        Task { try? await privacy.setExperienceMode(mode) }
    }

    var visibleSections: [LibrarySection] {
        LibrarySection.allCases.filter { section in
            switch section {
            case .workspaces: experienceMode != .basic
            case .automation: experienceMode != .basic
            case .dataLab: experienceMode == .analytics
            default: true
            }
        }
    }

    func updateHotKey(keyCode: UInt32, modifiers: UInt32, display: String) {
        installHotKey(keyCode: keyCode, modifiers: modifiers, display: display, persist: true)
    }

    func resetHotKey() {
        installHotKey(
            keyCode: UInt32(kVK_ANSI_V),
            modifiers: UInt32(cmdKey | shiftKey),
            display: "⌘⇧V",
            persist: true
        )
    }

    var indexedItemCount: Int {
        items.count
    }

    var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    func deleteAllHistory() {
        Task {
            do {
                let deleting = items
                try await repository.deleteAll()
                await syncCoordinator.syncDeletions(deleting)
                selectedItemID = nil
                await refresh()
            } catch {
                errorMessage = String(localized: "storage.error")
            }
        }
    }

    func exportJSON() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "AIClipboard-export.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DataExporter().json(items: items).write(to: url, options: .atomic)
        } catch {
            errorMessage = String(localized: "export.error")
        }
    }

    private func seedDevelopmentData() async {
        let values = [
            "docker exec -it mini_amazon_postgres psql -U postgres -d mini_amazon",
            "https://developer.apple.com/documentation/appkit/nspasteboard",
            "uvicorn app.main:app --reload --port 8001",
            "Нужно написать работодателю после собеседования",
            "Rick Owens DRKSHDW Jumbo Lace Low",
            "lsof -i :5432"
        ]
        for value in values {
            _ = await pipeline.process(.init(
                plainText: value,
                sourceApplication: .init(bundleIdentifier: "com.aiclipboard.seed", applicationName: "Development Seed")
            ))
        }
    }

    func selectNext(_ offset: Int) {
        guard !searchResults.isEmpty else { return }
        let current = searchResults.firstIndex { $0.id == selectedItemID } ?? 0
        let next = min(max(current + offset, 0), searchResults.count - 1)
        selectedItemID = searchResults[next].id
    }

    var selectedSearchItem: ClipboardItem? {
        searchResults.first { $0.id == selectedItemID }?.item
    }

    func selectSection(_ section: LibrarySection) {
        if section == .protected {
            let context = LAContext()
            var policyError: NSError?
            guard context.canEvaluatePolicy(
                .deviceOwnerAuthentication,
                error: &policyError
            ) else {
                errorMessage = AppLocalization.string(
                    "protected.authUnavailable",
                    languageCode: languageCode
                )
                return
            }
            context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: AppLocalization.string(
                    "protected.sectionAuthReason",
                    languageCode: languageCode
                )
            ) { [weak self] success, _ in
                guard success else { return }
                Task { @MainActor in
                    self?.applySection(.protected)
                }
            }
            return
        }
        applySection(section)
    }

    private func filters(for section: LibrarySection) -> SearchFilters {
        return switch section {
        case .pinned: SearchFilters(pinnedOnly: true)
        case .links: SearchFilters(contentType: .url)
        case .images: SearchFilters(contentType: .image)
        case .protected: SearchFilters(sensitiveOnly: true)
        default: SearchFilters()
        }
    }

    private func sectionItems(from source: [ClipboardItem]) -> [ClipboardItem] {
        source.filter { matches($0, section: selectedSection) }
    }

    func matches(_ item: ClipboardItem, section: LibrarySection) -> Bool {
        if item.isSensitive, section != .protected {
            return false
        }
        return switch section {
        case .ai, .workspaces, .automation, .dataLab: false
        case .all, .recent: true
        case .pinned: item.isPinned
        case .favorites: item.isFavorite
        case .text:
            [.plainText, .richText, .contact, .address, .date, .bankDetails, .formula].contains(item.contentType)
        case .links: item.contentType == .url
        case .code:
            [.code, .terminalCommand, .json, .xml, .yaml, .markdown, .csv, .table].contains(item.contentType)
        case .images: item.contentType == .image || item.contentType == .screenshot
        case .files: [.file, .folder, .fileList].contains(item.contentType)
        case .protected: item.isSensitive
        case .trash: false
        }
    }

    private func consolidateExistingDuplicates() async throws {
        let allItems = try await repository.recent(limit: 10_000, filters: .init())
        let normalizer = TextNormalizer()
        var textGroups: [String: [ClipboardItem]] = [:]
        for item in allItems where isTextualContent(item.contentType) {
            let value = item.contentType == .url
                ? canonicalURLString(item.sourceURL ?? item.normalizedText ?? item.rawText ?? "")
                : normalizer.normalize(item.normalizedText ?? item.rawText ?? "")
            guard !value.isEmpty else { continue }
            let canonicalHash = contentHash(
                .plainText,
                normalizedText: value,
                fileReferences: []
            )
            textGroups[canonicalHash, default: []].append(item)
        }
        for (canonicalHash, group) in textGroups {
            let ordered = group.sorted {
                if $0.isSensitive != $1.isSensitive { return !$0.isSensitive }
                return $0.updatedAt > $1.updatedAt
            }
            guard let keeper = ordered.first else { continue }
            try await repository.updateContentHash(id: keeper.id, hash: canonicalHash)
            for duplicate in ordered.dropFirst() {
                try await repository.mergeDuplicate(keeping: keeper.id, removing: duplicate.id)
            }
        }

        var imageGroups: [String: [ClipboardItem]] = [:]
        for item in allItems where item.contentType == .image {
            guard let path = item.imagePath else { continue }
            let canonicalData = await Task.detached {
                ImageCanonicalizer.canonicalPNG(path: path)
            }.value
            if let canonicalData {
                let canonicalHash = contentHash(
                    .image,
                    normalizedText: "",
                    fileReferences: [],
                    binaryContent: canonicalData
                )
                imageGroups[canonicalHash, default: []].append(item)
            }
        }
        for (canonicalHash, group) in imageGroups {
            let ordered = group.sorted { $0.updatedAt > $1.updatedAt }
            guard let keeper = ordered.first else { continue }
            try await repository.updateContentHash(id: keeper.id, hash: canonicalHash)
            for duplicate in ordered.dropFirst() {
                try await repository.mergeDuplicate(keeping: keeper.id, removing: duplicate.id)
                if let duplicatePath = duplicate.imagePath,
                   duplicatePath != keeper.imagePath {
                    try? FileManager.default.removeItem(atPath: duplicatePath)
                }
            }
        }
    }

    private func isTextualContent(_ type: ClipboardContentType) -> Bool {
        switch type {
        case .plainText, .richText, .url, .code, .terminalCommand, .emailAddress,
             .phoneNumber, .contact, .address, .date, .bankDetails, .color, .formula,
             .json, .xml, .yaml, .markdown, .csv, .table:
            true
        case .image, .screenshot, .file, .folder, .fileList, .unknown:
            false
        }
    }

    private func deduplicatedForMigration(_ source: [ClipboardItem]) -> [ClipboardItem] {
        var result: [String: ClipboardItem] = [:]
        for item in source {
            guard let key = logicalContentKey(item) else {
                result["id|\(item.id.uuidString)"] = item
                continue
            }
            if let existing = result[key] {
                var keeper = existing.updatedAt >= item.updatedAt ? existing : item
                let other = keeper.id == existing.id ? item : existing
                keeper.usageCount += other.usageCount
                keeper.isPinned = keeper.isPinned || other.isPinned
                keeper.isFavorite = keeper.isFavorite || other.isFavorite
                keeper.isSensitive = keeper.isSensitive || other.isSensitive
                if keeper.sensitivityType == nil {
                    keeper.sensitivityType = other.sensitivityType
                }
                result[key] = keeper
            } else {
                result[key] = item
            }
        }
        return Array(result.values)
    }

    private func normalizeRemoteHistory() async {
        guard let remoteItems = try? await repository.recent(limit: 50_000, filters: .init()) else { return }
        var groups: [String: [ClipboardItem]] = [:]
        for item in remoteItems {
            if let key = logicalContentKey(item) {
                groups[key, default: []].append(item)
            }
        }
        var removed: [ClipboardItem] = []
        for group in groups.values {
            let ordered = group.sorted {
                if $0.isSensitive != $1.isSensitive { return $0.isSensitive }
                return $0.updatedAt > $1.updatedAt
            }
            guard let keeper = ordered.first else { continue }
            for duplicate in ordered.dropFirst() {
                try? await repository.mergeDuplicate(keeping: keeper.id, removing: duplicate.id)
                removed.append(duplicate)
            }
        }
        if !removed.isEmpty {
            await syncCoordinator.syncDeletions(removed)
        }
        if let normalized = try? await repository.recent(limit: 50_000, filters: .init()) {
            _ = await syncCoordinator.syncNow(items: normalized)
        }
    }

    private func logicalContentKey(_ item: ClipboardItem) -> String? {
        if isTextualContent(item.contentType) {
            let normalizer = TextNormalizer()
            let value = item.contentType == .url
                ? canonicalURLString(item.sourceURL ?? item.normalizedText ?? item.rawText ?? "")
                : normalizer.normalize(item.normalizedText ?? item.rawText ?? "")
            guard !value.isEmpty else { return nil }
            return "text|\(value)"
        }
        if item.contentType == .image {
            if let data = item.imageData
                ?? item.imagePath.flatMap({ try? Data(contentsOf: URL(fileURLWithPath: $0)) }) {
                return "image|\(contentHash(.image, normalizedText: "", fileReferences: [], binaryContent: data))"
            }
            return "image|\(item.contentHash)"
        }
        return nil
    }

    private func presentAccountPromptIfNeeded(_ settings: PrivacySettings.Snapshot) {
        guard settings.accountPromptShown != true, accountStore.session == nil else { return }
        Task {
            try? await privacy.markAccountPromptShown()
            showAccount()
        }
    }

    private func handleAccountChange(_ session: UserSession?) {
        guard activeAccountID != session?.id else { return }
        activeAccountID = session?.id
        syncCoordinator.activateAccount(email: session?.email)
        items = []
        searchResults = []
        selectedItemID = nil
        selectedSection = .all
        Task {
            try? await repository.deleteAll()
            if syncCoordinator.isConfigured {
                await syncServerHistory()
            }
            await refresh()
        }
    }

    private func applySection(_ section: LibrarySection) {
        selectedSection = section
        query = ""
        selectedItemID = nil
        if section != .ai {
            Task { await refresh() }
        }
    }

    private func installHotKey(
        keyCode: UInt32,
        modifiers: UInt32,
        display: String,
        persist: Bool
    ) {
        let previousKeyCode = hotKeyKeyCode
        let previousModifiers = hotKeyModifiers
        hotKey = nil
        guard let replacement = GlobalHotKey(
            keyCode: keyCode,
            modifiers: modifiers,
            callback: { [weak self] in self?.showQuickSearch() }
        ) else {
            hotKey = GlobalHotKey(
                keyCode: previousKeyCode,
                modifiers: previousModifiers,
                callback: { [weak self] in self?.showQuickSearch() }
            )
            errorMessage = String(localized: "hotkey.error.unavailable")
            return
        }
        hotKey = replacement
        hotKeyKeyCode = keyCode
        hotKeyModifiers = modifiers
        hotKeyDisplay = display
        if persist {
            Task {
                do {
                    try await privacy.setHotKey(
                        keyCode: keyCode,
                        modifiers: modifiers,
                        display: display
                    )
                } catch {
                    errorMessage = String(localized: "settings.error")
                }
            }
        }
    }

    private func schedulePauseStatusRefresh(until date: Date?) {
        pauseStatusTask?.cancel()
        guard let date, date != .distantFuture else { return }
        let delay = max(0, date.timeIntervalSinceNow)
        pauseStatusTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            isPaused = await privacy.isPaused()
        }
    }

    private static func applicationSupportDirectory() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["AI_CLIPBOARD_SUPPORT_DIRECTORY"],
           !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let url = base.appendingPathComponent("AIClipboard", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

enum LibrarySection: String, CaseIterable, Identifiable {
    case ai, all, recent, pinned, favorites, text, links, code, images, files
    case workspaces, automation, dataLab, protected, trash
    var id: Self { self }
    var localizationKey: String { "sidebar.\(rawValue)" }
    var symbol: String {
        switch self {
        case .ai: "sparkles"
        case .workspaces: "square.grid.2x2"
        case .automation: "point.3.connected.trianglepath.dotted"
        case .dataLab: "chart.xyaxis.line"
        case .all: "square.stack.3d.up"
        case .recent: "clock"
        case .pinned: "pin"
        case .favorites: "star"
        case .text: "text.alignleft"
        case .links: "link"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .images: "photo"
        case .files: "doc"
        case .protected: "lock.shield"
        case .trash: "trash"
        }
    }
}
