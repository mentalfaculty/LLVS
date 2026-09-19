//
//  OneDriveAuthenticator.swift
//  LLVSOneDrive
//
//  Created by Drew McCormack on 03/03/2026.
//

import Foundation
import LLVS
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

/// Manages OAuth 2.0 authentication for Microsoft OneDrive via Microsoft Identity Platform.
///
/// Handles the full OAuth 2.0 authorization code flow: opening the browser,
/// exchanging the authorization code for tokens, storing tokens in the Keychain,
/// and automatically refreshing expired access tokens.
///
/// Interactive authorization requires `AuthenticationServices` and is available
/// on iOS 16+ and macOS 13+.
///
/// ```swift
/// let config = OneDriveAuthenticator.Configuration(
///     clientID: "your-app-client-id",
///     redirectURI: "msauth.com.yourapp://auth"
/// )
/// let authenticator = OneDriveAuthenticator(configuration: config)
///
/// // First time: interactive authorization
/// await authenticator.authorize(presenting: window)
///
/// // Create file system — tokens refresh automatically
/// let fs = OneDriveFileSystem(authenticator: authenticator)
/// ```
public final class OneDriveAuthenticator: Sendable {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// The Application (client) ID from Azure App Registration.
        public let clientID: String

        /// The redirect URI registered in Azure App Registration.
        public let redirectURI: String

        /// OAuth 2.0 scopes. Defaults to `Files.ReadWrite` and `offline_access`.
        public let scopes: [String]

        /// The Azure AD tenant. Defaults to `common` (personal + work accounts).
        public let tenant: String

        public init(
            clientID: String,
            redirectURI: String,
            scopes: [String] = ["Files.ReadWrite", "offline_access"],
            tenant: String = "common"
        ) {
            self.clientID = clientID
            self.redirectURI = redirectURI
            self.scopes = scopes
            self.tenant = tenant
        }
    }

    // MARK: - Stored Credential

    struct StoredCredential: OAuthCredential {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
    }

    // MARK: - Properties

    public let configuration: Configuration

    private var authorizationURL: URL {
        URL(string: "https://login.microsoftonline.com/\(configuration.tenant)/oauth2/v2.0/authorize")!
    }

    private var tokenURL: URL {
        URL(string: "https://login.microsoftonline.com/\(configuration.tenant)/oauth2/v2.0/token")!
    }

    /// Holds the credential and makes sure only one refresh is ever in flight.
    private let tokens: OAuthTokenStore<StoredCredential>

    private let http: HTTPClient

    // MARK: - Initialization

    /// - Parameters:
    ///   - session: Pass your own to control networking. Mainly for tests.
    ///   - retryPolicy: How hard to try again when the identity service is busy or briefly broken.
    ///   - sleeper: Waits between attempts. Tests supply their own, so they do not really sleep.
    public convenience init(configuration: Configuration, session: URLSession? = nil, retryPolicy: HTTPClient.RetryPolicy = .default, sleeper: (any HTTPSleeper)? = nil) {
        self.init(
            configuration: configuration,
            storage: nil,
            session: session,
            retryPolicy: retryPolicy,
            sleeper: sleeper
        )
    }

    /// - Parameter storage: Where to keep the credential. Nil uses the Keychain. Mainly for tests.
    init(configuration: Configuration, storage: (any OAuthCredentialStorage)?, session: URLSession? = nil, retryPolicy: HTTPClient.RetryPolicy = .default, sleeper: (any HTTPSleeper)? = nil) {
        self.configuration = configuration
        let resolvedSession: URLSession
        if let session {
            resolvedSession = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            resolvedSession = URLSession(configuration: config)
        }
        self.http = HTTPClient(session: resolvedSession, policy: retryPolicy, sleeper: sleeper)
        if let storage {
            self.tokens = OAuthTokenStore(storage: storage)
        } else {
            self.tokens = OAuthTokenStore(keychainService: "com.llvs.onedrive.\(configuration.clientID)")
        }
    }

    // MARK: - Public API

    /// Whether the user has previously authorized (has a stored refresh token).
    public var isAuthorized: Bool {
        get async { await tokens.credential?.refreshToken != nil }
    }

    /// Returns a valid access token, refreshing if expired.
    public func validAccessToken() async throws -> String {
        guard let cred = await tokens.credential else {
            throw CloudFileSystemError.authenticationFailed
        }

        // If token is still valid (with 60-second buffer), return it
        if cred.expiresAt.timeIntervalSinceNow > 60 {
            return cred.accessToken
        }

        return try await refreshAccessToken()
    }

    /// Discards the current access token and gets a new one.
    ///
    /// Call this after a 401. The stored token may look unexpired and still be refused, because the
    /// server can revoke it early.
    /// - Parameter staleAccessToken: The token that was refused, so a refresh already under way
    ///   cannot answer with that same token.
    public func freshAccessToken(replacing staleAccessToken: String? = nil) async throws -> String {
        try await refreshAccessToken(replacing: staleAccessToken)
    }

    /// Clears stored tokens and deauthorizes.
    public func deauthorize() async {
        await tokens.clear()
    }

    /// Puts a credential in place without going through the browser. For tests.
    func seed(accessToken: String, refreshToken: String, expiresAt: Date) async {
        await tokens.store(StoredCredential(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt))
    }

    // MARK: - Interactive Authorization

    #if canImport(AuthenticationServices)

    @MainActor
    public func authorize(presenting anchor: ASPresentationAnchor) async throws {
        // PKCE ties the code to this app: the verifier never leaves the device, and the code is
        // worthless to anyone who intercepts it on the redirect without it
        let pkce = PKCEChallenge()
        let state = OAuthState.make()
        let code = try await obtainAuthorizationCode(presenting: anchor, pkce: pkce, state: state)
        try await exchangeCodeForTokens(code, verifier: pkce.verifier)
    }

    @MainActor
    private func obtainAuthorizationCode(presenting anchor: ASPresentationAnchor, pkce: PKCEChallenge, state: String) async throws -> String {
        let scope = configuration.scopes.joined(separator: " ")
        var components = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        let authURL = components.url!

        guard let callbackScheme = URL(string: configuration.redirectURI)?.scheme else {
            throw CloudFileSystemError.authenticationFailed
        }

        return try await withCheckedThrowingContinuation { continuation in
            let anchorProvider = AnchorProvider(anchor: anchor)
            // Nothing else holds the session once start() returns, and a released session dismisses
            // its own sheet. The box is captured by the closure, so the session lives until it fires
            let sessionBox = SessionBox()
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                // Capturing the box is what keeps the session alive; letting go here breaks the
                // cycle between the session and this closure
                defer { sessionBox.session = nil; sessionBox.anchorProvider = nil }

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

                // A callback whose state is not the one we sent did not come from our request
                let returnedState = components.queryItems?.first(where: { $0.name == "state" })?.value
                guard let returnedState, OAuthState.matches(returnedState, state) else {
                    continuation.resume(throwing: CloudFileSystemError.authenticationFailed)
                    return
                }

                continuation.resume(returning: code)
            }

            session.presentationContextProvider = anchorProvider
            session.prefersEphemeralWebBrowserSession = false
            sessionBox.session = session
            sessionBox.anchorProvider = anchorProvider
            session.start()
        }
    }

    /// Holds the authentication session and its context provider alive while the sheet is up.
    ///
    /// Both need it. `presentationContextProvider` is a weak property, and nothing else refers to
    /// the session once `start()` returns, so without this the sheet can dismiss itself.
    @MainActor
    private final class SessionBox {
        var session: ASWebAuthenticationSession?
        var anchorProvider: AnchorProvider?
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

    private func exchangeCodeForTokens(_ code: String, verifier: String) async throws {
        let body = [
            "code": code,
            "client_id": configuration.clientID,
            "redirect_uri": configuration.redirectURI,
            "grant_type": "authorization_code",
            "scope": configuration.scopes.joined(separator: " "),
            "code_verifier": verifier,
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
        await tokens.store(cred)
    }

    /// Refreshes the access token, with only one refresh in flight at a time.
    ///
    /// Several uploads running at once all see the token expire together. Without this they would
    /// each refresh, and Microsoft may invalidate the older refresh tokens as it issues new ones, so
    /// the last one home could leave a good credential broken. Callers arriving during a refresh
    /// await the one already running instead of starting another.
    private func refreshAccessToken(replacing staleAccessToken: String? = nil) async throws -> String {
        try await tokens.refresh(replacing: staleAccessToken) { [self] refreshToken in
            let body = [
                "refresh_token": refreshToken,
                "client_id": configuration.clientID,
                "grant_type": "refresh_token",
                "scope": configuration.scopes.joined(separator: " "),
            ]

            let tokenResponse = try await performTokenRequest(body)

            guard let accessToken = tokenResponse["access_token"] as? String,
                  let expiresIn = tokenResponse["expires_in"] as? Int else {
                throw CloudFileSystemError.authenticationFailed
            }

            // Microsoft may return a new refresh token — use it if present
            let newRefreshToken = tokenResponse["refresh_token"] as? String ?? refreshToken

            return StoredCredential(
                accessToken: accessToken,
                refreshToken: newRefreshToken,
                expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn))
            )
        }
    }

    private func performTokenRequest(_ body: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyString = body.map { "\($0.key)=\(urlEncode($0.value))" }.joined(separator: "&")
        let bodyData = Data(bodyString.utf8)

        // A token request is safe to repeat: the same code or refresh token gives the same answer,
        // and a busy identity service is exactly the case worth waiting out
        let response = try await http.perform(request, uploading: bodyData)

        guard (200..<300).contains(response.statusCode) else {
            throw CloudFileSystemError.authenticationFailed
        }

        guard let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw CloudFileSystemError.authenticationFailed
        }

        return json
    }

    private func urlEncode(_ string: String) -> String {
        // The default set leaves "+" and "&" alone, which would corrupt a form body
        string.addingPercentEncoding(withAllowedCharacters: .oauthFormAllowed) ?? string
    }

}
