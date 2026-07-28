import Foundation

public enum ClipboardContentType: String, Codable, CaseIterable, Sendable {
    case plainText, richText, url, code, terminalCommand, emailAddress, phoneNumber
    case contact, address, date, bankDetails, color, formula
    case json, xml, yaml, markdown, csv, table
    case image, screenshot, file, folder, fileList, unknown

    public var displayName: String {
        switch self {
        case .plainText: "Text"
        case .richText: "Rich text"
        case .url: "Link"
        case .code: "Code"
        case .terminalCommand: "Command"
        case .emailAddress: "Email"
        case .phoneNumber: "Phone"
        case .contact: "Contact"
        case .address: "Address"
        case .date: "Date"
        case .bankDetails: "Bank details"
        case .color: "Color"
        case .formula: "Formula"
        case .json: "JSON"
        case .xml: "XML"
        case .yaml: "YAML"
        case .markdown: "Markdown"
        case .csv: "CSV"
        case .table: "Table"
        case .image: "Image"
        case .screenshot: "Screenshot"
        case .file: "File"
        case .folder: "Folder"
        case .fileList: "Files"
        case .unknown: "Other"
        }
    }
}

public enum SensitivityType: String, Codable, Sendable {
    case password, oneTimeCode, apiKey, accessToken, privateKey, seedPhrase
    case paymentCard, connectionString, cookie, session, cloudCredential, personalData
}

public enum SensitivePolicy: String, Codable, CaseIterable, Sendable {
    case neverSave, saveEncrypted, saveFor30Seconds, saveFor5Minutes, saveLocallyOnly, askEveryTime
}

public enum RetentionPolicy: String, Codable, Sendable {
    case forever, oneDay, sevenDays, thirtyDays, ninetyDays
}

public enum ProcessingStatus: String, Codable, Sendable {
    case captured, persisted, indexed, failed
}

public struct SourceApplication: Codable, Hashable, Sendable {
    public var bundleIdentifier: String
    public var applicationName: String
    public var applicationPath: String?

    public init(bundleIdentifier: String, applicationName: String, applicationPath: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.applicationPath = applicationPath
    }
}

public struct FileReference: Codable, Hashable, Sendable {
    public var path: String
    public var displayName: String
    public var size: Int64?

    public init(path: String, displayName: String, size: Int64? = nil) {
        self.path = path
        self.displayName = displayName
        self.size = size
    }
}

public struct CapturedContent: Sendable {
    public var plainText: String?
    public var richText: Data?
    public var imageData: Data?
    public var fileReferences: [FileReference]
    public var sourceApplication: SourceApplication?
    public var sourceWindowTitle: String?
    public var capturedAt: Date

    public init(
        plainText: String? = nil,
        richText: Data? = nil,
        imageData: Data? = nil,
        fileReferences: [FileReference] = [],
        sourceApplication: SourceApplication? = nil,
        sourceWindowTitle: String? = nil,
        capturedAt: Date = Date()
    ) {
        self.plainText = plainText
        self.richText = richText
        self.imageData = imageData
        self.fileReferences = fileReferences
        self.sourceApplication = sourceApplication
        self.sourceWindowTitle = sourceWindowTitle
        self.capturedAt = capturedAt
    }
}

public struct ClipboardItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var contentType: ClipboardContentType
    public var rawText: String?
    public var normalizedText: String?
    public var richTextData: Data?
    public var imagePath: String?
    public var imageData: Data?
    public var fileReferences: [FileReference]
    public var sourceApplication: SourceApplication?
    public var sourceWindowTitle: String?
    public var sourceURL: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?
    public var usageCount: Int
    public var isPinned: Bool
    public var isFavorite: Bool
    public var isSensitive: Bool
    public var sensitivityType: SensitivityType?
    public var retentionPolicy: RetentionPolicy
    public var contentHash: String
    public var language: String?
    public var title: String?
    public var summary: String?
    public var tags: [String]
    public var processingStatus: ProcessingStatus

    public init(
        id: UUID = UUID(),
        contentType: ClipboardContentType,
        rawText: String? = nil,
        normalizedText: String? = nil,
        richTextData: Data? = nil,
        imagePath: String? = nil,
        imageData: Data? = nil,
        fileReferences: [FileReference] = [],
        sourceApplication: SourceApplication? = nil,
        sourceWindowTitle: String? = nil,
        sourceURL: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastUsedAt: Date? = nil,
        usageCount: Int = 1,
        isPinned: Bool = false,
        isFavorite: Bool = false,
        isSensitive: Bool = false,
        sensitivityType: SensitivityType? = nil,
        retentionPolicy: RetentionPolicy = .forever,
        contentHash: String,
        language: String? = nil,
        title: String? = nil,
        summary: String? = nil,
        tags: [String] = [],
        processingStatus: ProcessingStatus = .captured
    ) {
        self.id = id
        self.contentType = contentType
        self.rawText = rawText
        self.normalizedText = normalizedText
        self.richTextData = richTextData
        self.imagePath = imagePath
        self.imageData = imageData
        self.fileReferences = fileReferences
        self.sourceApplication = sourceApplication
        self.sourceWindowTitle = sourceWindowTitle
        self.sourceURL = sourceURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.usageCount = usageCount
        self.isPinned = isPinned
        self.isFavorite = isFavorite
        self.isSensitive = isSensitive
        self.sensitivityType = sensitivityType
        self.retentionPolicy = retentionPolicy
        self.contentHash = contentHash
        self.language = language
        self.title = title
        self.summary = summary
        self.tags = tags
        self.processingStatus = processingStatus
    }
}

public struct SearchFilters: Codable, Hashable, Sendable {
    public var from: Date?
    public var to: Date?
    public var applicationName: String?
    public var contentType: ClipboardContentType?
    public var pinnedOnly: Bool
    public var sensitiveOnly: Bool
    public var sensitivity: Bool?
    public var containsText: String?
    public var projectName: String?

    public init(
        from: Date? = nil,
        to: Date? = nil,
        applicationName: String? = nil,
        contentType: ClipboardContentType? = nil,
        pinnedOnly: Bool = false,
        sensitiveOnly: Bool = false,
        sensitivity: Bool? = nil,
        containsText: String? = nil,
        projectName: String? = nil
    ) {
        self.from = from
        self.to = to
        self.applicationName = applicationName
        self.contentType = contentType
        self.pinnedOnly = pinnedOnly
        self.sensitiveOnly = sensitiveOnly
        self.sensitivity = sensitivity
        self.containsText = containsText
        self.projectName = projectName
    }
}

public enum ExperienceMode: String, Codable, CaseIterable, Sendable {
    case basic, work, development, analytics
}

public struct SourceContext: Codable, Hashable, Sendable {
    public var applicationName: String?
    public var windowTitle: String?
    public var pageTitle: String?
    public var sourceURL: String?
    public var projectName: String?
    public var deviceName: String?
    public var language: String?

    public init(
        applicationName: String? = nil,
        windowTitle: String? = nil,
        pageTitle: String? = nil,
        sourceURL: String? = nil,
        projectName: String? = nil,
        deviceName: String? = nil,
        language: String? = nil
    ) {
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.pageTitle = pageTitle
        self.sourceURL = sourceURL
        self.projectName = projectName
        self.deviceName = deviceName
        self.language = language
    }
}

public struct SearchQuery: Sendable {
    public var rawQuery: String
    public var semanticQuery: String
    public var filters: SearchFilters
    public var semanticWeight: Double
    public var keywordWeight: Double
    public var limit: Int

    public init(
        rawQuery: String,
        semanticQuery: String? = nil,
        filters: SearchFilters = .init(),
        semanticWeight: Double = 0.38,
        keywordWeight: Double = 0.62,
        limit: Int = 50
    ) {
        self.rawQuery = rawQuery
        self.semanticQuery = semanticQuery ?? rawQuery
        self.filters = filters
        self.semanticWeight = semanticWeight
        self.keywordWeight = keywordWeight
        self.limit = limit
    }
}

public struct SearchResult: Identifiable, Sendable {
    public var id: UUID { item.id }
    public var item: ClipboardItem
    public var finalScore: Double
    public var keywordScore: Double
    public var semanticScore: Double
    public var recencyScore: Double
    public var usageScore: Double
    public var explanation: String
    public var matchedFragment: String?
}

public struct SecretFinding: Equatable, Sendable {
    public var type: SensitivityType
    public var confidence: Double
    public var recommendedPolicy: SensitivePolicy
}

public struct PipelineOutcome: Sendable {
    public enum Disposition: Equatable, Sendable { case stored, deduplicated, rejectedSensitive, excluded, empty }
    public var disposition: Disposition
    public var itemID: UUID?
}
