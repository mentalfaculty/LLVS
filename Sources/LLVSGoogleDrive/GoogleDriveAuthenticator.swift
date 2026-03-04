//
//  GoogleDriveAuthenticator.swift
//  LLVSGoogleDrive
//
//  Created by Drew McCormack on 03/03/2026.
//

import Foundation
import LLVS
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

/// Manages OAuth 2.0 authentication for Google Drive.
///
/// Handles the full OAuth 2.0 authorization code flow: opening the browser,
/// exchanging the authorization code for tokens, storing tokens in the Keychain,
/// and automatically refreshing expired access tokens.
///
/// Interactive authorization requires `AuthenticationServices` and is available
/// on iOS 16+ and macOS 13+.
///
/// ```swift
/// let config = GoogleDriveAuthenticator.Configuration(
///     clientID: "your-client-id.apps.googleusercontent.com",
///     redirectURI: "com.yourapp:/oauth2callback"
/// )
/// let authenticator = GoogleDriveAuthenticator(configuration: config)
///
/// // First time: interactive authorization
/// await authenticator.authorize(presenting: window)
///
/// // Create file system — tokens refresh automatically
/// let fs = GoogleDriveFileSystem(authenticator: authenticator)
/// ```
public final class GoogleDriveAuthenticator: @unchecked Sendable {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// The OAuth 2.0 client ID from the Google Cloud Console.
        public let clientID: String

        /// The redirect URI registered in the Google Cloud Console.
        public let redirectURI: String

        /// OAuth 2.0 scopes. Defaults to `drive.file` (per-file access).
        public let scopes: [String]

        public init(
            clientID: String,
            redirectURI: String,
            scopes: [String] = ["https://www.googleapis.com/auth/drive.file"]
        ) {
            self.clientID = clientID
            self.redirectURI = redirectURI
            self.scopes = scopes
        }
    }

    // MARK: - Stored Credential

    private struct StoredCredential: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
    }

    // MARK: - Properties

    public let configuration: Configuration

    private static let authorizationURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    private var credential: StoredCredential?

    private var keychainService: String {
        "com.llvs.googledrive.\(configuration.clientID)"
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    // MARK: - Initialization

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.credential = loadCredentialFromKeychain()
    }

    // MARK: - Public API

    /// Whether the user has previously authorized (has a stored refresh token).
    public var isAuthorized: Bool {
        credential?.refreshToken != nil
    }

    /// Returns a valid access token, refreshing if expired.
    public func validAccessToken() async throws -> String {
        guard let cred = credential else {
            throw CloudFileSystemError.authenticationFailed
        }

        // If token is still valid (with 60-second buffer), return it
        if cred.expiresAt.timeIntervalSinceNow > 60 {
            return cred.accessToken
        }

        return try await refreshAccessToken(refreshToken: cred.refreshToken)
    }

    /// Clears stored tokens and deauthorizes.
    public func deauthorize() {
        credential = nil
        deleteCredentialFromKeychain()
    }

    // MARK: - Interactive Authorization

    #if canImport(AuthenticationServices)

    @MainActor
    public func authorize(presenting anchor: ASPresentationAnchor) async throws {
        let code = try await obtainAuthorizationCode(presenting: anchor)
        try await exchangeCodeForTokens(code)
    }

    @MainActor
    private func obtainAuthorizationCode(presenting anchor: ASPresentationAnchor) async throws -> String {
        let scope = configuration.scopes.joined(separator: " ")
        var components = URLComponents(url: Self.authorizationURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]

        let authURL = components.url!

        guard let callbackScheme = URL(string: configuration.redirectURI)?.scheme else {
            throw CloudFileSystemError.authenticationFailed
        }

        return try await withCheckedThrowingContinuation { continuation in
            let anchorProvider = AnchorProvider(anchor: anchor)
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                withExtendedLifetime(anchorProvider) {}

                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let callbackURL,
                      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                    continuation.resume(throwing: CloudFileSystemError.authenticationFailed)
                    return
                }

                continuation.resume(returning: code)
            }

            session.presentationContextProvider = anchorProvider
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    private final class AnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
        let anchor: ASPresentationAnchor

        init(anchor: ASPresentationAnchor) {
            self.anchor = anchor
        }

        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            anchor
        }
    }

    #endif

    // MARK: - Token Exchange

    private func exchangeCodeForTokens(_ code: String) async throws {
        let body = [
            "code": code,
            "client_id": configuration.clientID,
            "redirect_uri": configuration.redirectURI,
            "grant_type": "authorization_code",
        ]

        let tokenResponse = try await performTokenRequest(body)

        guard let accessToken = tokenResponse["access_token"] as? String,
              let refreshToken = tokenResponse["refresh_token"] as? String,
              let expiresIn = tokenResponse["expires_in"] as? Int else {
            throw CloudFileSystemError.authenticationFailed
        }

        let cred = StoredCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn))
        )
        credential = cred
        saveCredentialToKeychain(cred)
    }

    private func refreshAccessToken(refreshToken: String) async throws -> String {
        let body = [
            "refresh_token": refreshToken,
            "client_id": configuration.clientID,
            "grant_type": "refresh_token",
        ]

        let tokenResponse = try await performTokenRequest(body)

        guard let accessToken = tokenResponse["access_token"] as? String,
              let expiresIn = tokenResponse["expires_in"] as? Int else {
            throw CloudFileSystemError.authenticationFailed
        }

        let cred = StoredCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn))
        )
        credential = cred
        saveCredentialToKeychain(cred)
        return accessToken
    }

    private func performTokenRequest(_ body: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyString = body.map { "\($0.key)=\(urlEncode($0.value))" }.joined(separator: "&")
        request.httpBody = bodyString.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200..<300).contains(statusCode) else {
            throw CloudFileSystemError.authenticationFailed
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudFileSystemError.authenticationFailed
        }

        return json
    }

    private func urlEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? string
    }

    // MARK: - Keychain

    private func saveCredentialToKeychain(_ credential: StoredCredential) {
        guard let data = try? JSONEncoder().encode(credential) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "credential",
        ]

        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func loadCredentialFromKeychain() -> StoredCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "credential",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return try? JSONDecoder().decode(StoredCredential.self, from: data)
    }

    private func deleteCredentialFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "credential",
        ]
        SecItemDelete(query as CFDictionary)
    }
}
