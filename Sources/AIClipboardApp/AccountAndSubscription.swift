import AppKit
import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import StoreKit

enum AccountProvider: String, Codable {
    case email, google
}

struct UserSession: Codable, Equatable {
    var id: String
    var email: String
    var displayName: String
    var provider: AccountProvider
}

enum AccountError: LocalizedError {
    case invalidEmail, weakPassword, accountExists, invalidCredentials
    case googleNotConfigured, invalidOAuthResponse, network(String)

    var errorDescription: String? {
        switch self {
        case .invalidEmail: String(localized: "account.error.email")
        case .weakPassword: String(localized: "account.error.password")
        case .accountExists: String(localized: "account.error.exists")
        case .invalidCredentials: String(localized: "account.error.credentials")
        case .googleNotConfigured: String(localized: "account.error.googleConfig")
        case .invalidOAuthResponse: String(localized: "account.error.oauth")
        case .network: String(localized: "account.error.network")
        }
    }
}

@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var session: UserSession?
    @Published var errorMessage: String?
    @Published var isWorking = false
    var onSessionChanged: ((UserSession?) -> Void)?
    var emailAuthenticator: ((
        _ email: String,
        _ password: String,
        _ displayName: String?,
        _ register: Bool
    ) async throws -> UserSession)?

    private let sessionURL: URL
    private let google = GoogleOAuthService()

    init(directory: URL) throws {
        sessionURL = directory.appendingPathComponent("account-session.json")
        // Email identity now belongs to the remote backend. Remove the obsolete
        // password-hash store created by pre-cloud versions.
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent("local-account.json")
        )
        if let data = try? Data(contentsOf: sessionURL) {
            session = try? JSONDecoder().decode(UserSession.self, from: data)
        }
    }

    func register(email: String, password: String, displayName: String) {
        performAsync {
            let normalizedEmail = try self.validatedEmail(email)
            guard password.count >= 12 else { throw AccountError.weakPassword }
            guard let authenticator = self.emailAuthenticator else {
                throw AccountError.network("server_not_configured")
            }
            let cleanedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return try await authenticator(
                normalizedEmail,
                password,
                cleanedName.isEmpty
                    ? normalizedEmail.split(separator: "@").first.map(String.init) ?? normalizedEmail
                    : cleanedName,
                true
            )
        }
    }

    func signIn(email: String, password: String) {
        performAsync {
            let normalizedEmail = try self.validatedEmail(email)
            guard let authenticator = self.emailAuthenticator else {
                throw AccountError.network("server_not_configured")
            }
            return try await authenticator(
                normalizedEmail,
                password,
                nil,
                false
            )
        }
    }

    func signInWithGoogle() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                let profile = try await google.signIn()
                try establish(profile)
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    func signOut() {
        session = nil
        try? FileManager.default.removeItem(at: sessionURL)
        onSessionChanged?(nil)
    }

    private func performAsync(
        _ operation: @escaping @MainActor () async throws -> UserSession
    ) {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try establish(try await operation())
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func establish(_ value: UserSession) throws {
        try writeProtected(value, to: sessionURL)
        session = value
        onSessionChanged?(value)
    }

    private func validatedEmail(_ value: String) throws -> String {
        let email = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.range(
            of: #"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil else { throw AccountError.invalidEmail }
        return email
    }

    private func writeProtected<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

}

@MainActor
private final class GoogleOAuthService: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func signIn() async throws -> UserSession {
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "GoogleOAuthClientID") as? String,
              !clientID.isEmpty,
              !clientID.contains("REPLACE"),
              let callbackScheme = Bundle.main.object(forInfoDictionaryKey: "GoogleOAuthCallbackScheme") as? String,
              !callbackScheme.isEmpty,
              !callbackScheme.contains("REPLACE")
        else { throw AccountError.googleNotConfigured }

        let verifier = randomURLSafeString(length: 64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = randomURLSafeString(length: 32)
        let redirectURI = "\(callbackScheme):/oauth2redirect"
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "openid email profile"),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256")
        ]
        guard let authorizationURL = components?.url else { throw AccountError.invalidOAuthResponse }

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let webSession = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: callbackScheme
            ) { url, error in
                if let error { continuation.resume(throwing: error); return }
                guard let url else {
                    continuation.resume(throwing: AccountError.invalidOAuthResponse)
                    return
                }
                continuation.resume(returning: url)
            }
            webSession.presentationContextProvider = self
            webSession.prefersEphemeralWebBrowserSession = false
            session = webSession
            if !webSession.start() {
                continuation.resume(throwing: AccountError.invalidOAuthResponse)
            }
        }
        let query = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard query.first(where: { $0.name == "state" })?.value == state,
              let code = query.first(where: { $0.name == "code" })?.value else {
            throw AccountError.invalidOAuthResponse
        }
        return try await exchange(
            code: code,
            verifier: verifier,
            clientID: clientID,
            redirectURI: redirectURI
        )
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
        }
    }

    private func exchange(
        code: String,
        verifier: String,
        clientID: String,
        redirectURI: String
    ) async throws -> UserSession {
        guard let tokenURL = URL(string: "https://oauth2.googleapis.com/token") else {
            throw AccountError.invalidOAuthResponse
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = [
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI
        ].map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let idToken = object["id_token"] as? String else {
            throw AccountError.network("token_exchange")
        }
        let parts = idToken.split(separator: ".")
        guard parts.count == 3,
              let payloadData = Data(base64URL: String(parts[1])),
              let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let subject = payload["sub"] as? String,
              let email = payload["email"] as? String else {
            throw AccountError.invalidOAuthResponse
        }
        return UserSession(
            id: subject,
            email: email,
            displayName: payload["name"] as? String ?? email,
            provider: .google
        )
    }

    private func randomURLSafeString(length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0..<length).map { _ in alphabet[Int.random(in: alphabet.indices)] })
    }
}

@MainActor
final class SubscriptionManager: ObservableObject {
    static let productIDs = [
        "com.aiclipboard.pro.monthly",
        "com.aiclipboard.pro.yearly"
    ]

    @Published private(set) var products: [Product] = []
    @Published private(set) var isSubscribed = false
    @Published var isWorking = false
    @Published var errorMessage: String?
    private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = Task {
            for await update in Transaction.updates {
                guard case .verified(let transaction) = update else { continue }
                await transaction.finish()
                await refreshEntitlements()
            }
        }
        Task { await reload() }
    }

    deinit { updatesTask?.cancel() }

    func reload() async {
        isWorking = true
        do {
            products = try await Product.products(for: Self.productIDs)
                .sorted { $0.price < $1.price }
            await refreshEntitlements()
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }

    func purchase(_ product: Product) {
        isWorking = true
        Task {
            do {
                let result = try await product.purchase()
                if case .success(.verified(let transaction)) = result {
                    await transaction.finish()
                    await refreshEntitlements()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    func restore() {
        isWorking = true
        Task {
            do {
                try await AppStore.sync()
                await refreshEntitlements()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func refreshEntitlements() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  Self.productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil else { continue }
            active = true
        }
        isSubscribed = active
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var value = base64URL.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        self.init(base64Encoded: value)
    }
}
