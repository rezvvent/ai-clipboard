import CryptoKit
import Foundation
import Security

public struct TextNormalizer: TextNormalizing {
    public init() {}

    public func normalize(_ text: String) -> String {
        var value = text.precomposedStringWithCanonicalMapping
        value = value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "[\\u{200B}-\\u{200D}\\u{FEFF}]", with: "", options: .regularExpression)
        let lines = value.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: "[\\t ]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct ContentDetector: ContentDetecting {
    private let commandPrefixes = [
        "docker ", "git ", "npm ", "pnpm ", "yarn ", "pip ", "python ", "uvicorn ",
        "ssh ", "curl ", "grep ", "lsof ", "systemctl ", "brew ", "kubectl ", "swift "
    ]

    public init() {}

    public func detect(text: String, hasImage: Bool, files: [FileReference]) -> ClipboardContentType {
        if !files.isEmpty { return files.count > 1 ? .fileList : .file }
        if hasImage { return .image }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return hasImage ? .image : .unknown }

        if isJSON(trimmed) { return .json }
        if trimmed.hasPrefix("<"), trimmed.hasSuffix(">"),
           trimmed.range(of: #"^<([A-Za-z_][\w:.-]*)(\s[^>]*)?>[\s\S]*</\1>$"#, options: .regularExpression) != nil {
            return .xml
        }
        if let url = URL(string: trimmed), url.scheme != nil, url.host != nil { return .url }
        if matches(trimmed, #"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$"#) { return .emailAddress }
        if matches(trimmed, #"^\+?[\d\s().-]{7,20}$"#), trimmed.filter(\.isNumber).count >= 7 { return .phoneNumber }
        if matches(trimmed, #"^(#[0-9A-F]{3,8}|rgba?\([^)]+\)|hsla?\([^)]+\))$"#) { return .color }

        let lower = trimmed.lowercased()
        if commandPrefixes.contains(where: { lower.hasPrefix($0) }) || lower.hasPrefix("$ ") { return .terminalCommand }
        if looksLikeCode(trimmed) { return .code }
        if looksLikeMarkdown(trimmed) { return .markdown }
        return .plainText
    }

    private func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func isJSON(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              value is [String: Any] || value is [Any] else { return false }
        return true
    }

    private func looksLikeCode(_ text: String) -> Bool {
        let patterns = [
            #"\b(func|class|struct|enum|protocol|import|let|var|guard)\b"#,
            #"\b(def|async def|from|lambda|elif)\b"#,
            #"\b(const|function|interface|export|=>)\b"#,
            #"\b(SELECT|INSERT|UPDATE|DELETE|CREATE TABLE|JOIN)\b"#,
            #"\b(package|public static void|fun|data class)\b"#,
            #"[{};]\s*$"#
        ]
        let hits = patterns.reduce(0) { $0 + (matches(text, $1) ? 1 : 0) }
        return hits >= 1 && (text.contains("\n") || text.contains("{") || text.contains(";"))
    }

    private func looksLikeMarkdown(_ text: String) -> Bool {
        matches(text, #"(?m)^(#{1,6}\s|[-*]\s|\d+\.\s|>\s|```)"#)
    }
}

public struct SecretDetector: SecretDetecting {
    public init() {}

    public func detect(in text: String) -> SecretFinding? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if contains(#"-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----"#, in: trimmed) {
            return .init(type: .privateKey, confidence: 1, recommendedPolicy: .neverSave)
        }
        if contains(#"^aiclip1_[A-Za-z0-9_-]{43}$"#, in: trimmed) {
            return .init(type: .accessToken, confidence: 1, recommendedPolicy: .neverSave)
        }
        if looksLikeSeedPhrase(trimmed) {
            return .init(type: .seedPhrase, confidence: 0.98, recommendedPolicy: .neverSave)
        }
        if contains(#"\b\d{3}\s?\d{3}\b"#, in: trimmed), trimmed.count <= 12 {
            return .init(type: .oneTimeCode, confidence: 0.88, recommendedPolicy: .neverSave)
        }
        if contains(#"\b(eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,})\b"#, in: trimmed) {
            return .init(type: .accessToken, confidence: 0.99, recommendedPolicy: .saveEncrypted)
        }
        if contains(#"(?i)\b(bearer\s+[A-Za-z0-9._~+/=-]{16,}|sk-[A-Za-z0-9_-]{16,}|gh[ps]_[A-Za-z0-9]{20,}|AKIA[A-Z0-9]{16})\b"#, in: trimmed) {
            return .init(type: .apiKey, confidence: 0.98, recommendedPolicy: .saveEncrypted)
        }
        if contains(#"(?i)\b(postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis)://[^:\s]+:[^@\s]+@"#, in: trimmed) {
            return .init(type: .connectionString, confidence: 0.98, recommendedPolicy: .saveEncrypted)
        }
        if let digits = paymentCardDigits(in: trimmed), luhn(digits) {
            return .init(type: .paymentCard, confidence: 0.97, recommendedPolicy: .saveEncrypted)
        }
        if contains(#"(?i)\b(password|passwd|пароль)\s*[:=]\s*\S{4,}"#, in: trimmed) {
            return .init(type: .password, confidence: 0.95, recommendedPolicy: .neverSave)
        }
        if highEntropyToken(in: trimmed) {
            return .init(type: .accessToken, confidence: 0.72, recommendedPolicy: .saveLocallyOnly)
        }
        return nil
    }

    private func contains(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private func looksLikeSeedPhrase(_ text: String) -> Bool {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace)
        guard [12, 15, 18, 21, 24].contains(words.count) else { return false }
        return words.allSatisfy { $0.range(of: #"^[a-zа-яё]{3,12}$"#, options: .regularExpression) != nil }
    }

    private func paymentCardDigits(in text: String) -> [Int]? {
        guard text.range(of: #"^\s*(?:\d[ -]?){13,19}\s*$"#, options: .regularExpression) != nil else { return nil }
        return text.compactMap(\.wholeNumberValue)
    }

    private func luhn(_ digits: [Int]) -> Bool {
        guard digits.count >= 13 else { return false }
        let sum = digits.reversed().enumerated().reduce(0) { total, pair in
            var value = pair.element
            if pair.offset % 2 == 1 {
                value *= 2
                if value > 9 { value -= 9 }
            }
            return total + value
        }
        return sum % 10 == 0
    }

    private func highEntropyToken(in text: String) -> Bool {
        guard text.count >= 28, text.count <= 256, !text.contains(" ") else { return false }
        guard text.range(of: #"^[A-Za-z0-9_+=-]+$"#, options: .regularExpression) != nil else { return false }
        let alphabet = Set(text)
        let probability = alphabet.reduce(0.0) { partial, character in
            let count = text.filter { $0 == character }.count
            let p = Double(count) / Double(text.count)
            return partial - p * log2(p)
        }
        return probability > 4.3
    }
}

public struct MultilingualLocalEmbeddingProvider: EmbeddingProviding {
    public let dimensions: Int
    private let aliases: [String: String] = [
        "база": "database", "базу": "database", "postgresql": "database", "postgres": "database",
        "контейнер": "docker", "контейнера": "docker", "документация": "documentation",
        "буфер": "clipboard", "обмена": "clipboard", "команда": "command",
        "запуск": "run", "запуска": "run", "ссылка": "url", "порт": "port",
        "войти": "exec", "зайти": "exec", "входил": "exec", "проверить": "check",
        "работодатель": "employer", "собеседование": "interview", "обувь": "shoes"
    ]

    public init(dimensions: Int = 384) { self.dimensions = dimensions }

    public func embed(_ text: String) async throws -> [Float] {
        var vector = Array(repeating: Float(0), count: dimensions)
        let normalized = text.lowercased()
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        var tokens = normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        tokens.append(contentsOf: tokens.compactMap { aliases[$0] })

        for token in tokens {
            let wrapped = "^" + token + "$"
            let chars = Array(wrapped.utf8)
            for width in 2...min(5, chars.count) where chars.count >= width {
                for start in 0...(chars.count - width) {
                    let gram = chars[start..<(start + width)]
                    var hash: UInt64 = 1469598103934665603
                    for byte in gram {
                        hash = (hash ^ UInt64(byte)) &* 1099511628211
                    }
                    let index = Int(hash % UInt64(dimensions))
                    vector[index] += (hash & 1 == 0) ? 1 : -1
                }
            }
        }
        return normalize(vector)
    }

    private func normalize(_ value: [Float]) -> [Float] {
        let magnitude = sqrt(value.reduce(Float(0)) { $0 + $1 * $1 })
        guard magnitude > 0 else { return value }
        return value.map { $0 / magnitude }
    }
}

public struct ServerOnlyEmbeddingProvider: EmbeddingProviding {
    public let dimensions = 0

    public init() {}

    public func embed(_ text: String) async throws -> [Float] {
        throw ServerOnlyEmbeddingError.disabled
    }
}

public enum ServerOnlyEmbeddingError: Error {
    case disabled
}

public enum EncryptionError: Error { case keychain(OSStatus), invalidCiphertext }

public final class KeychainEncryptionService: ContentEncrypting, @unchecked Sendable {
    private let service: String
    private let account = "protected-content-key"
    private let key: SymmetricKey

    public init(service: String = "com.aiclipboard.local") throws {
        self.service = service
        self.key = SymmetricKey(data: try Self.loadOrCreateKey(service: service, account: account))
    }

    public func encrypt(_ data: Data) throws -> Data {
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else { throw EncryptionError.invalidCiphertext }
        return combined
    }

    public func decrypt(_ data: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
    }

    private static func loadOrCreateKey(service: String, account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return data }
        guard status == errSecItemNotFound else { throw EncryptionError.keychain(status) }
        let data = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        var add = query
        add.removeValue(forKey: kSecReturnData as String)
        add.removeValue(forKey: kSecMatchLimit as String)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw EncryptionError.keychain(addStatus) }
        return data
    }
}

/// Password-prompt-free key storage for ad-hoc development builds.
/// Production distributions should use `KeychainEncryptionService` with a stable Developer ID signature.
public final class FileBackedEncryptionService: ContentEncrypting, @unchecked Sendable {
    private let key: SymmetricKey

    public init(keyURL: URL) throws {
        let keyData: Data
        if FileManager.default.fileExists(atPath: keyURL.path) {
            keyData = try Data(contentsOf: keyURL)
            guard keyData.count == 32 else { throw EncryptionError.invalidCiphertext }
        } else {
            try FileManager.default.createDirectory(
                at: keyURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            keyData = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
            try keyData.write(to: keyURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: keyURL.path
            )
        }
        key = SymmetricKey(data: keyData)
    }

    public func encrypt(_ data: Data) throws -> Data {
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else { throw EncryptionError.invalidCiphertext }
        return combined
    }

    public func decrypt(_ data: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
    }
}

public func contentHash(
    _ type: ClipboardContentType,
    normalizedText: String,
    fileReferences: [FileReference],
    binaryContent: Data? = nil
) -> String {
    let files = fileReferences.map(\.path).sorted().joined(separator: "\u{1F}")
    let binaryHash = binaryContent.map {
        SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
    } ?? ""
    let source = "\(type.rawValue)\u{1E}\(normalizedText)\u{1E}\(files)\u{1E}\(binaryHash)"
    return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
}

public func canonicalURLString(_ value: String) -> String {
    guard var components = URLComponents(string: value),
          let scheme = components.scheme?.lowercased(),
          let host = components.host?.lowercased() else { return value }
    components.scheme = scheme
    components.host = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
        components.port = nil
    }
    if components.path == "/" && components.query == nil && components.fragment == nil {
        components.path = ""
    }
    return components.string ?? value
}

public func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Double {
    guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
    let dot = zip(lhs, rhs).reduce(Float(0)) { $0 + $1.0 * $1.1 }
    let left = sqrt(lhs.reduce(Float(0)) { $0 + $1 * $1 })
    let right = sqrt(rhs.reduce(Float(0)) { $0 + $1 * $1 })
    guard left > 0, right > 0 else { return 0 }
    return Double(dot / (left * right))
}
