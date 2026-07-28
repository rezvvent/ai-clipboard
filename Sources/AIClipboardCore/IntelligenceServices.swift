import Foundation

public enum QuickTextAction: String, CaseIterable, Sendable {
    case clean, plainText, uppercase, lowercase, bulletList, extractURLs, summarize
}

public struct QuickTextTransformer: Sendable {
    public init() {}

    public func apply(_ action: QuickTextAction, to input: String) -> String {
        switch action {
        case .clean:
            return TextNormalizer().normalize(input)
        case .plainText:
            return input
                .replacingOccurrences(of: #"[`*_>#]"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\[(.*?)\]\((.*?)\)"#, with: "$1 ($2)", options: .regularExpression)
        case .uppercase:
            return input.uppercased()
        case .lowercase:
            return input.lowercased()
        case .bulletList:
            return input.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { "• \($0)" }.joined(separator: "\n")
        case .extractURLs:
            guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
                return ""
            }
            let range = NSRange(input.startIndex..., in: input)
            return detector.matches(in: input, range: range).compactMap(\.url?.absoluteString).joined(separator: "\n")
        case .summarize:
            let sentences = input.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return sentences.prefix(3).joined(separator: ". ") + (sentences.isEmpty ? "" : ".")
        }
    }
}

public enum TabularColumnType: String, Codable, Sendable {
    case integer, decimal, boolean, date, email, url, text, empty
}

public struct TabularColumnProfile: Codable, Hashable, Sendable {
    public var name: String
    public var type: TabularColumnType
    public var missingCount: Int
    public var uniqueCount: Int
    public var isPotentialPII: Bool
}

public struct TabularProfile: Codable, Hashable, Sendable {
    public var delimiter: String
    public var rowCount: Int
    public var columnCount: Int
    public var duplicateRowCount: Int
    public var columns: [TabularColumnProfile]
}

public struct TabularProfiler: Sendable {
    public init() {}

    public func profile(_ text: String) -> TabularProfile? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count >= 2 else { return nil }
        let delimiter: Character = lines[0].filter { $0 == "\t" }.count > lines[0].filter { $0 == "," }.count ? "\t" : ","
        let rows = lines.map { parseRow($0, delimiter: delimiter) }
        guard let header = rows.first, header.count >= 2, rows.dropFirst().allSatisfy({ $0.count == header.count }) else {
            return nil
        }
        let data = Array(rows.dropFirst())
        let columns = header.indices.map { index in
            let values = data.map { $0[index].trimmingCharacters(in: .whitespacesAndNewlines) }
            return TabularColumnProfile(
                name: header[index],
                type: inferType(values),
                missingCount: values.filter(\.isEmpty).count,
                uniqueCount: Set(values.filter { !$0.isEmpty }).count,
                isPotentialPII: isPII(name: header[index], values: values)
            )
        }
        return TabularProfile(
            delimiter: String(delimiter),
            rowCount: data.count,
            columnCount: header.count,
            duplicateRowCount: data.count - Set(data.map { $0.joined(separator: "\u{1F}") }).count,
            columns: columns
        )
    }

    private func parseRow(_ line: String, delimiter: Character) -> [String] {
        var result = [String](), field = "", quoted = false
        for character in line {
            if character == "\"" { quoted.toggle() }
            else if character == delimiter && !quoted { result.append(field); field = "" }
            else { field.append(character) }
        }
        result.append(field)
        return result
    }

    private func inferType(_ values: [String]) -> TabularColumnType {
        let values = values.filter { !$0.isEmpty }
        guard !values.isEmpty else { return .empty }
        if values.allSatisfy({ Int($0) != nil }) { return .integer }
        if values.allSatisfy({ Double($0.replacingOccurrences(of: ",", with: ".")) != nil }) { return .decimal }
        if values.allSatisfy({ ["true", "false", "yes", "no", "да", "нет", "0", "1"].contains($0.lowercased()) }) { return .boolean }
        if values.allSatisfy({ $0.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil }) { return .date }
        if values.allSatisfy({ $0.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil }) { return .email }
        if values.allSatisfy({ URL(string: $0)?.scheme != nil }) { return .url }
        return .text
    }

    private func isPII(name: String, values: [String]) -> Bool {
        let name = name.lowercased()
        if ["email", "e-mail", "phone", "телефон", "почта", "address", "адрес", "name", "имя"].contains(where: name.contains) {
            return true
        }
        return values.contains {
            $0.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil
        }
    }
}
