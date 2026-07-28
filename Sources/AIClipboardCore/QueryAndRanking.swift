import Foundation

public struct QueryParser: Sendable {
    public init() {}

    public func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current) -> SearchQuery {
        let lower = input.lowercased()
        var filters = SearchFilters()
        var semantic = input

        let operators = parseOperators(input)
        if let value = operators["type"], let type = contentType(value) {
            filters.contentType = type
        }
        if let value = operators["app"] ?? operators["source"] {
            filters.applicationName = value
        }
        if let value = operators["contains"] {
            filters.containsText = value
        }
        if let value = operators["project"] {
            filters.projectName = value
        }
        if let value = operators["sensitive"] {
            filters.sensitivity = ["true", "yes", "1", "да"].contains(value.lowercased())
        }
        if let value = operators["copied"] ?? operators["date"] {
            applyDate(value, filters: &filters, now: now, calendar: calendar)
        }
        semantic = semantic.replacingOccurrences(
            of: #"\b(?:type|app|source|contains|project|sensitive|copied|date):(?:"[^"]+"|\S+)"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        if lower.contains("вчера") || lower.contains("yesterday") {
            let startToday = calendar.startOfDay(for: now)
            filters.from = calendar.date(byAdding: .day, value: -1, to: startToday)
            filters.to = startToday
            semantic = removing(["вчера", "yesterday"], from: semantic)
        } else if lower.contains("сегодня") || lower.contains("today") {
            filters.from = calendar.startOfDay(for: now)
            filters.to = calendar.date(byAdding: .day, value: 1, to: filters.from!)
            semantic = removing(["сегодня", "today"], from: semantic)
        }

        let typeTerms: [(ClipboardContentType, [String])] = [
            (.url, ["ссылк", "url", "link"]),
            (.terminalCommand, ["команд", "command"]),
            (.json, ["json"]),
            (.image, ["изображен", "картинк", "image"]),
            (.file, ["файл", "file"]),
            (.code, ["код", "code"])
        ]
        for (type, terms) in typeTerms where filters.contentType == nil && terms.contains(where: lower.contains) {
            filters.contentType = type
            break
        }

        let applications = ["Chrome", "Safari", "Telegram", "Slack", "Xcode", "Terminal", "Finder"]
        if filters.applicationName == nil, let app = applications.first(where: { lower.contains($0.lowercased()) }) {
            filters.applicationName = app
            semantic = semantic.replacingOccurrences(of: app, with: "", options: .caseInsensitive)
        }
        semantic = semantic.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SearchQuery(rawQuery: input, semanticQuery: semantic, filters: filters)
    }

    private func removing(_ terms: [String], from text: String) -> String {
        terms.reduce(text) { $0.replacingOccurrences(of: $1, with: "", options: .caseInsensitive) }
    }

    private func parseOperators(_ input: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"\b(type|app|source|contains|project|sensitive|copied|date):("[^"]+"|\S+)"#,
            options: .caseInsensitive
        ) else { return [:] }
        let range = NSRange(input.startIndex..., in: input)
        return regex.matches(in: input, range: range).reduce(into: [:]) { result, match in
            guard let keyRange = Range(match.range(at: 1), in: input),
                  let valueRange = Range(match.range(at: 2), in: input) else { return }
            result[String(input[keyRange]).lowercased()] = String(input[valueRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
    }

    private func contentType(_ value: String) -> ClipboardContentType? {
        let aliases: [String: ClipboardContentType] = [
            "text": .plainText, "текст": .plainText, "url": .url, "link": .url, "ссылка": .url,
            "code": .code, "код": .code, "sql": .code, "command": .terminalCommand,
            "команда": .terminalCommand, "json": .json, "xml": .xml, "markdown": .markdown,
            "image": .image, "изображение": .image, "file": .file, "файл": .file,
            "email": .emailAddress, "phone": .phoneNumber
        ]
        return aliases[value.lowercased()] ?? ClipboardContentType(rawValue: value)
    }

    private func applyDate(_ value: String, filters: inout SearchFilters, now: Date, calendar: Calendar) {
        switch value.lowercased().replacingOccurrences(of: "-", with: "_") {
        case "today", "сегодня":
            filters.from = calendar.startOfDay(for: now)
        case "yesterday", "вчера":
            let today = calendar.startOfDay(for: now)
            filters.from = calendar.date(byAdding: .day, value: -1, to: today)
            filters.to = today
        case "this_week", "week", "неделя":
            filters.from = calendar.dateInterval(of: .weekOfYear, for: now)?.start
        case "this_month", "month", "месяц":
            filters.from = calendar.dateInterval(of: .month, for: now)?.start
        default:
            break
        }
    }
}

public struct RankingConfiguration: Sendable {
    public var keywordWeight = 0.62
    public var semanticWeight = 0.38
    public var recencyWeight = 0.08
    public var usageWeight = 0.04
    public var pinnedBoost = 0.12
    public init() {}
}

public struct HybridRanker: Sendable {
    public var configuration: RankingConfiguration
    public init(configuration: RankingConfiguration = .init()) { self.configuration = configuration }

    public func score(
        item: ClipboardItem,
        keyword: Double,
        semantic: Double,
        now: Date = Date()
    ) -> SearchResult {
        let days = max(0, now.timeIntervalSince(item.createdAt) / 86_400)
        let recency = exp(-days / 30)
        let usage = min(1, log1p(Double(item.usageCount)) / log(20))
        var final = keyword * configuration.keywordWeight
            + max(0, semantic) * configuration.semanticWeight
            + recency * configuration.recencyWeight
            + usage * configuration.usageWeight
        if item.isPinned { final += configuration.pinnedBoost }
        let reason: String
        if keyword >= semantic && keyword > 0 { reason = "Exact text match" }
        else if semantic > 0 { reason = "Meaning match" }
        else { reason = "Recent item" }
        return SearchResult(
            item: item,
            finalScore: final,
            keywordScore: keyword,
            semanticScore: semantic,
            recencyScore: recency,
            usageScore: usage,
            explanation: reason,
            matchedFragment: nil
        )
    }
}
