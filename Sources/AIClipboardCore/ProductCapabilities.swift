import Foundation

// MARK: - Product modules and shared entities

public enum ProductModule: String, Codable, CaseIterable, Sendable {
    case clipboardCore, aiActions, knowledgeWorkspaces, automationStudio, dataLab
}

public enum IntelligenceMode: String, Codable, CaseIterable, Sendable {
    case cloud, corporate
}

public struct KnowledgeWorkspace: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var details: String
    public var itemIDs: [UUID]
    public var tags: [String]
    public var businessTerms: [BusinessTerm]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        details: String = "",
        itemIDs: [UUID] = [],
        tags: [String] = [],
        businessTerms: [BusinessTerm] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.details = details
        self.itemIDs = itemIDs
        self.tags = tags
        self.businessTerms = businessTerms
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct BusinessTerm: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var definition: String
    public var formula: String?

    public init(id: UUID = UUID(), name: String, definition: String, formula: String? = nil) {
        self.id = id
        self.name = name
        self.definition = definition
        self.formula = formula
    }
}

public enum TeamRole: String, Codable, Sendable {
    case viewer, editor, approver, owner
}

public struct TeamSpace: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var members: [String: TeamRole]
    public var workspaceIDs: [UUID]
    public var auditEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        members: [String: TeamRole] = [:],
        workspaceIDs: [UUID] = [],
        auditEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.members = members
        self.workspaceIDs = workspaceIDs
        self.auditEnabled = auditEnabled
    }
}

// MARK: - Context-aware paste and format conversion

public enum PasteDestination: String, Codable, CaseIterable, Sendable {
    case plainText, messenger, markdown, html, spreadsheet, json, sql, terminal, latex, jira, confluence
}

public struct ContextAwarePasteEngine: Sendable {
    public init() {}

    public func adapt(_ text: String, destination: PasteDestination) -> String {
        switch destination {
        case .plainText:
            return QuickTextTransformer().apply(.plainText, to: text)
        case .messenger:
            return sentenceCase(TextNormalizer().normalize(text))
        case .markdown:
            return markdown(text)
        case .html:
            return "<p>\(escapeHTML(TextNormalizer().normalize(text)).replacingOccurrences(of: "\n", with: "<br>"))</p>"
        case .spreadsheet:
            return table(text)?.map { $0.joined(separator: "\t") }.joined(separator: "\n") ?? text
        case .json:
            return json(text)
        case .sql:
            let values = text.split(whereSeparator: \.isNewline).map { "'\(sqlEscape(String($0)))'" }
            return values.count > 1 ? "(\(values.joined(separator: ", ")))" : values.first ?? "''"
        case .terminal:
            return "'\(text.replacingOccurrences(of: "'", with: "'\\''"))'"
        case .latex:
            return text.replacingOccurrences(of: #"([#$%&_{}])"#, with: #"\\$1"#, options: .regularExpression)
        case .jira:
            return text.replacingOccurrences(of: #"(?m)^# (.+)$"#, with: "h1. $1", options: .regularExpression)
        case .confluence:
            return text.replacingOccurrences(of: #"(?m)^##? (.+)$"#, with: "h2. $1", options: .regularExpression)
        }
    }

    private func sentenceCase(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst().lowercased()
    }

    private func markdown(_ text: String) -> String {
        guard let rows = table(text), rows.count > 1 else { return text }
        let header = "| " + rows[0].joined(separator: " | ") + " |"
        let divider = "| " + rows[0].map { _ in "---" }.joined(separator: " | ") + " |"
        return ([header, divider] + rows.dropFirst().map { "| " + $0.joined(separator: " | ") + " |" })
            .joined(separator: "\n")
    }

    private func json(_ text: String) -> String {
        if let rows = table(text), rows.count > 1 {
            let header = rows[0]
            let objects = rows.dropFirst().map { row in
                Dictionary(uniqueKeysWithValues: zip(header, row).map { ($0, $1) })
            }
            if let data = try? JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys]) {
                return String(decoding: data, as: UTF8.self)
            }
        }
        return #"{"value":"\#(text.replacingOccurrences(of: "\"", with: "\\\""))"}"#
    }

    private func table(_ text: String) -> [[String]]? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count > 1 else { return nil }
        let delimiter: Character = lines[0].contains("\t") ? "\t" : ","
        let rows = lines.map { $0.split(separator: delimiter, omittingEmptySubsequences: false).map(String.init) }
        return rows.dropFirst().allSatisfy { $0.count == rows[0].count } ? rows : nil
    }

    private func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func sqlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "'", with: "''")
    }
}

// MARK: - SQL Copilot

public enum SQLSeverity: String, Codable, Sendable {
    case info, warning, critical
}

public struct SQLFinding: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var severity: SQLSeverity
    public var title: String
    public var detail: String
    public var line: Int?

    public init(id: UUID = UUID(), severity: SQLSeverity, title: String, detail: String, line: Int? = nil) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
        self.line = line
    }
}

public struct SQLAnalysis: Codable, Hashable, Sendable {
    public var formattedSQL: String
    public var statementType: String
    public var referencedTables: [String]
    public var findings: [SQLFinding]
    public var requiresConfirmation: Bool
}

public struct SQLCopilot: Sendable {
    public init() {}

    public func analyze(_ sql: String) -> SQLAnalysis {
        let normalized = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = normalized.uppercased()
        let statement = upper.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "UNKNOWN"
        var findings = [SQLFinding]()
        if (statement == "DELETE" || statement == "UPDATE") &&
            upper.range(of: #"\bWHERE\b"#, options: .regularExpression) == nil {
            findings.append(.init(
                severity: .critical,
                title: "Missing WHERE",
                detail: "\(statement) affects every matching row and requires explicit confirmation."
            ))
        }
        if upper.contains("SELECT *") {
            findings.append(.init(severity: .warning, title: "SELECT *", detail: "Select only required columns to reduce transfer and schema coupling."))
        }
        if upper.range(of: #"\b(CROSS JOIN|DROP TABLE|TRUNCATE)\b"#, options: .regularExpression) != nil {
            findings.append(.init(severity: .critical, title: "Heavy operation", detail: "Review the execution scope before running this statement."))
        }
        if upper.contains(" JOIN "), upper.range(of: #"\bON\b"#, options: .regularExpression) == nil {
            findings.append(.init(severity: .warning, title: "Join without ON", detail: "The query may create a Cartesian product."))
        }
        return SQLAnalysis(
            formattedSQL: format(normalized),
            statementType: statement,
            referencedTables: tables(normalized),
            findings: findings,
            requiresConfirmation: findings.contains { $0.severity == .critical }
        )
    }

    public func convertToPandas(_ sql: String) -> String {
        let escaped = sql.replacingOccurrences(of: "\"\"\"", with: "\\\"\\\"\\\"")
        return "query = \"\"\"\n\(escaped)\n\"\"\"\ndf = pandas.read_sql_query(query, connection)"
    }

    private func tables(_ sql: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\b(?:FROM|JOIN|UPDATE|INTO|TABLE)\s+([A-Za-z_][\w.]*)"#, options: .caseInsensitive) else {
            return []
        }
        let range = NSRange(sql.startIndex..., in: sql)
        return Array(Set(regex.matches(in: sql, range: range).compactMap { match in
            Range(match.range(at: 1), in: sql).map { String(sql[$0]) }
        })).sorted()
    }

    private func format(_ sql: String) -> String {
        let keywords = ["select", "from", "where", "group by", "order by", "having", "limit", "join", "left join", "right join", "inner join", "union", "values", "set"]
        var result = sql.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        for keyword in keywords.sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(
                of: "\\b\(NSRegularExpression.escapedPattern(for: keyword))\\b",
                with: keyword.uppercased(),
                options: [.regularExpression, .caseInsensitive]
            )
        }
        for keyword in ["FROM", "WHERE", "GROUP BY", "ORDER BY", "HAVING", "LIMIT", "JOIN", "LEFT JOIN", "RIGHT JOIN", "INNER JOIN", "UNION"] {
            result = result.replacingOccurrences(of: " \(keyword) ", with: "\n\(keyword) ")
        }
        return result
    }
}

// MARK: - Dataset transformations, comparison, joins and lineage

public enum DataOperation: Codable, Hashable, Sendable {
    case removeDuplicates(columns: [String])
    case dropEmptyRows
    case renameColumn(from: String, to: String)
    case replace(column: String, from: String, to: String)
    case filterEquals(column: String, value: String)
}

public struct PipelineStep: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var operation: DataOperation
    public var isEnabled: Bool

    public init(id: UUID = UUID(), name: String, operation: DataOperation, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.operation = operation
        self.isEnabled = isEnabled
    }
}

public struct ClipboardPipeline: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var triggerType: ClipboardContentType?
    public var steps: [PipelineStep]
    public var keyboardShortcut: String?

    public init(
        id: UUID = UUID(),
        name: String,
        triggerType: ClipboardContentType? = nil,
        steps: [PipelineStep] = [],
        keyboardShortcut: String? = nil
    ) {
        self.id = id
        self.name = name
        self.triggerType = triggerType
        self.steps = steps
        self.keyboardShortcut = keyboardShortcut
    }
}

public struct PipelineRun: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var pipelineID: UUID
    public var sourceItemIDs: [UUID]
    public var startedAt: Date
    public var completedAt: Date
    public var appliedSteps: [UUID]
    public var output: String
}

public struct CSVTable: Codable, Hashable, Sendable {
    public var header: [String]
    public var rows: [[String]]

    public init?(text: String) {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count >= 2 else { return nil }
        let delimiter: Character = lines[0].contains("\t") ? "\t" : ","
        let values = lines.map { $0.split(separator: delimiter, omittingEmptySubsequences: false).map(String.init) }
        guard let first = values.first, first.count > 1, values.dropFirst().allSatisfy({ $0.count == first.count }) else {
            return nil
        }
        header = first
        rows = Array(values.dropFirst())
    }

    public func csv() -> String {
        ([header] + rows).map {
            $0.map { value in
                value.contains(",") || value.contains("\"")
                    ? "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
                    : value
            }.joined(separator: ",")
        }.joined(separator: "\n")
    }
}

public struct PipelineEngine: Sendable {
    public init() {}

    public func run(_ pipeline: ClipboardPipeline, input: String, sourceItemIDs: [UUID] = []) -> PipelineRun? {
        guard var table = CSVTable(text: input) else { return nil }
        let applied = pipeline.steps.filter(\.isEnabled)
        for step in applied {
            apply(step.operation, to: &table)
        }
        let now = Date()
        return PipelineRun(
            id: UUID(),
            pipelineID: pipeline.id,
            sourceItemIDs: sourceItemIDs,
            startedAt: now,
            completedAt: Date(),
            appliedSteps: applied.map(\.id),
            output: table.csv()
        )
    }

    private func apply(_ operation: DataOperation, to table: inout CSVTable) {
        switch operation {
        case .removeDuplicates(let columns):
            let indices = columns.compactMap { table.header.firstIndex(of: $0) }
            var seen = Set<String>()
            table.rows = table.rows.filter { row in
                let key = (indices.isEmpty ? row : indices.map { row[$0] }).joined(separator: "\u{1F}")
                return seen.insert(key).inserted
            }
        case .dropEmptyRows:
            table.rows.removeAll { $0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
        case .renameColumn(let from, let to):
            if let index = table.header.firstIndex(of: from) { table.header[index] = to }
        case .replace(let column, let from, let to):
            guard let index = table.header.firstIndex(of: column) else { return }
            for row in table.rows.indices where table.rows[row][index] == from { table.rows[row][index] = to }
        case .filterEquals(let column, let value):
            guard let index = table.header.firstIndex(of: column) else { return }
            table.rows.removeAll { $0[index] != value }
        }
    }
}

public struct DatasetDifference: Codable, Hashable, Sendable {
    public var addedRows: Int
    public var removedRows: Int
    public var addedColumns: [String]
    public var removedColumns: [String]
    public var changedCells: Int
}

public struct DatasetComparator: Sendable {
    public init() {}

    public func compare(_ old: CSVTable, _ new: CSVTable) -> DatasetDifference {
        let oldRows = Set(old.rows.map { $0.joined(separator: "\u{1F}") })
        let newRows = Set(new.rows.map { $0.joined(separator: "\u{1F}") })
        let sharedRows = min(old.rows.count, new.rows.count)
        let sharedColumns = min(old.header.count, new.header.count)
        var changed = 0
        for row in 0..<sharedRows {
            for column in 0..<sharedColumns where old.rows[row][column] != new.rows[row][column] {
                changed += 1
            }
        }
        return DatasetDifference(
            addedRows: newRows.subtracting(oldRows).count,
            removedRows: oldRows.subtracting(newRows).count,
            addedColumns: new.header.filter { !old.header.contains($0) },
            removedColumns: old.header.filter { !new.header.contains($0) },
            changedCells: changed
        )
    }
}

public struct JoinSuggestion: Codable, Hashable, Sendable {
    public var leftColumn: String
    public var rightColumn: String
    public var matchRatio: Double
    public var relationship: String
}

public struct JoinIntelligence: Sendable {
    public init() {}

    public func suggestions(left: CSVTable, right: CSVTable) -> [JoinSuggestion] {
        left.header.flatMap { leftName in
            right.header.compactMap { rightName in
                let normalizedLeft = leftName.lowercased().replacingOccurrences(of: "_id", with: "")
                let normalizedRight = rightName.lowercased().replacingOccurrences(of: "_id", with: "")
                guard leftName.caseInsensitiveCompare(rightName) == .orderedSame || normalizedLeft == normalizedRight else {
                    return nil
                }
                guard let li = left.header.firstIndex(of: leftName), let ri = right.header.firstIndex(of: rightName) else {
                    return nil
                }
                let leftValues = Set(left.rows.map { $0[li] })
                let rightValues = Set(right.rows.map { $0[ri] })
                let ratio = Double(leftValues.intersection(rightValues).count) / Double(max(1, leftValues.union(rightValues).count))
                let relationship = leftValues.count == left.rows.count
                    ? (rightValues.count == right.rows.count ? "one-to-one" : "one-to-many")
                    : "many-to-many"
                return JoinSuggestion(leftColumn: leftName, rightColumn: rightName, matchRatio: ratio, relationship: relationship)
            }
        }.sorted { $0.matchRatio > $1.matchRatio }
    }
}

public struct LineageNode: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var sourceItemIDs: [UUID]
    public var transformationIDs: [UUID]
    public var createdAt: Date
    public var actor: String
    public var model: String?

    public init(
        id: UUID = UUID(),
        name: String,
        sourceItemIDs: [UUID],
        transformationIDs: [UUID],
        createdAt: Date = Date(),
        actor: String,
        model: String? = nil
    ) {
        self.id = id
        self.name = name
        self.sourceItemIDs = sourceItemIDs
        self.transformationIDs = transformationIDs
        self.createdAt = createdAt
        self.actor = actor
        self.model = model
    }
}

// MARK: - Schema intelligence, recipes and validation

public struct SchemaIntelligence: Sendable {
    public init() {}

    public func jsonSchema(from text: String, title: String = "GeneratedObject") -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let schema: [String: Any] = [
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "title": title,
            "type": jsonType(object),
            "properties": properties(object)
        ]
        guard let output = try? JSONSerialization.data(withJSONObject: schema, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(decoding: output, as: UTF8.self)
    }

    private func jsonType(_ value: Any) -> String {
        switch value {
        case is [String: Any]: "object"
        case is [Any]: "array"
        case is Bool: "boolean"
        case is Int: "integer"
        case is NSNumber: "number"
        case is NSNull: "null"
        default: "string"
        }
    }

    private func properties(_ value: Any) -> [String: Any] {
        guard let object = value as? [String: Any] else { return [:] }
        return object.reduce(into: [:]) { result, pair in
            var definition: [String: Any] = ["type": jsonType(pair.value)]
            if pair.value is [String: Any] { definition["properties"] = properties(pair.value) }
            if let array = pair.value as? [Any], let first = array.first {
                definition["items"] = ["type": jsonType(first)]
            }
            result[pair.key] = definition
        }
    }
}

public struct DataValidationRule: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case nonNegative, percentage, unique, required, email, notFutureDate }
    public var id: UUID
    public var column: String
    public var kind: Kind

    public init(id: UUID = UUID(), column: String, kind: Kind) {
        self.id = id
        self.column = column
        self.kind = kind
    }
}

public struct DataValidationIssue: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var row: Int
    public var column: String
    public var message: String
}

public struct DataValidator: Sendable {
    public init() {}

    public func validate(_ table: CSVTable, rules: [DataValidationRule]) -> [DataValidationIssue] {
        var issues = [DataValidationIssue]()
        for rule in rules {
            guard let index = table.header.firstIndex(of: rule.column) else { continue }
            var seen = Set<String>()
            for (rowIndex, row) in table.rows.enumerated() {
                let value = row[index].trimmingCharacters(in: .whitespaces)
                let invalid: Bool
                switch rule.kind {
                case .nonNegative: invalid = (Double(value) ?? 0) < 0
                case .percentage: invalid = !(0...100).contains(Double(value) ?? -1)
                case .unique: invalid = !value.isEmpty && !seen.insert(value).inserted
                case .required: invalid = value.isEmpty
                case .email: invalid = value.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) == nil
                case .notFutureDate:
                    invalid = ISO8601DateFormatter().date(from: value).map { $0 > Date() } ?? false
                }
                if invalid {
                    issues.append(.init(id: UUID(), row: rowIndex + 2, column: rule.column, message: rule.kind.rawValue))
                }
            }
        }
        return issues
    }
}

public struct AutomationRecipe: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var summary: String
    public var trigger: String
    public var actions: [String]

    public init(id: UUID = UUID(), name: String, summary: String, trigger: String, actions: [String]) {
        self.id = id
        self.name = name
        self.summary = summary
        self.trigger = trigger
        self.actions = actions
    }
}

public enum RecipeLibrary {
    public static let builtIn: [AutomationRecipe] = [
        .init(name: "Clean CSV", summary: "Remove empty rows and duplicates.", trigger: "csv", actions: ["drop_empty_rows", "remove_duplicates", "profile"]),
        .init(name: "SQL Safety", summary: "Format SQL and detect dangerous operations.", trigger: "sql", actions: ["format", "safety_check"]),
        .init(name: "JSON to Schema", summary: "Generate JSON Schema from copied JSON.", trigger: "json", actions: ["json_schema"]),
        .init(name: "Remove personal data", summary: "Detect and mask emails and phone numbers.", trigger: "text", actions: ["detect_pii", "mask"]),
        .init(name: "Power BI preparation", summary: "Normalize headers, dates and categories.", trigger: "table", actions: ["normalize_headers", "normalize_dates", "profile"])
    ]
}
