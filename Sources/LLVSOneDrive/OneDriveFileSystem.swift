//
//  OneDriveFileSystem.swift
//  LLVSOneDrive
//
//  Created by Drew McCormack on 03/03/2026.
//

import Foundation
import LLVS

/// A `CloudFileSystem` backed by the Microsoft Graph REST API v1.0 using `URLSession`.
///
/// Microsoft Graph supports native path-based addressing using the colon syntax:
/// `/me/drive/root:/path/to/item:`. This means paths map directly to OneDrive paths
/// without any ID resolution or caching.
///
/// Two initialization paths are available:
/// ```swift
/// // Static access token (app manages refresh externally)
/// let fs = OneDriveFileSystem(accessToken: "your-token")
///
/// // Authenticator with auto-refresh
/// let fs = OneDriveFileSystem(authenticator: authenticator)
/// ```
public final class OneDriveFileSystem: CloudFileSystem, @unchecked Sendable {

    // MARK: - Properties

    private let tokenProvider: @Sendable () async throws -> String

    private static let graphBaseURL = URL(string: "https://graph.microsoft.com/v1.0")!

    private let http: HTTPClient

    /// Asks the authenticator for a new token after a 401. Nil when the caller supplied a static token.
    private let tokenRefresher: (@Sendable (String) async throws -> String)?

    /// The session used when none is supplied. Not lazy: a lazy var is not thread-safe.
    static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config)
    }

    // MARK: - Initialization

    /// Creates a OneDrive file system with a static access token.
    ///
    /// A static token cannot be refreshed, so a 401 is reported rather than retried.
    /// - Parameters:
    ///   - session: Pass your own to control networking. Mainly for tests.
    ///   - retryPolicy: How hard to try again when the server is busy or briefly broken.
    ///   - sleeper: Waits between attempts. Tests supply their own, so they do not really sleep.
    public init(accessToken: String, session: URLSession? = nil, retryPolicy: HTTPClient.RetryPolicy = .default, sleeper: (any HTTPSleeper)? = nil) {
        self.tokenProvider = { accessToken }
        self.tokenRefresher = nil
        self.http = HTTPClient(session: session ?? Self.makeDefaultSession(), policy: retryPolicy, sleeper: sleeper)
    }

    /// Creates a OneDrive file system with an authenticator that
    /// automatically refreshes expired tokens.
    /// - Parameters:
    ///   - session: Pass your own to control networking. Mainly for tests.
    ///   - retryPolicy: How hard to try again when the server is busy or briefly broken.
    ///   - sleeper: Waits between attempts. Tests supply their own, so they do not really sleep.
    public init(authenticator: OneDriveAuthenticator, session: URLSession? = nil, retryPolicy: HTTPClient.RetryPolicy = .default, sleeper: (any HTTPSleeper)? = nil) {
        self.tokenProvider = { try await authenticator.validAccessToken() }
        self.tokenRefresher = { staleToken in try await authenticator.freshAccessToken(replacing: staleToken) }
        self.http = HTTPClient(session: session ?? Self.makeDefaultSession(), policy: retryPolicy, sleeper: sleeper)
    }

    // MARK: - CloudFileSystem

    public func fileExists(at path: String) async throws -> Bool {
        let url = graphURL(forItemAtPath: path)
        let response = try await performAuthorized { token in
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }

        if response.statusCode == 404 { return false }
        if (200..<300).contains(response.statusCode) { return true }
        throw mapHTTPError(statusCode: response.statusCode)
    }

    public func contentsOfDirectory(at path: String) async throws -> [String] {
        let absPath = absolutePath(for: path)
        var allNames: [String] = []
        var nextURL: URL? = graphURL(forChildrenAtPath: absPath)

        while let currentURL = nextURL {
            let response = try await performAuthorized { token in
                var request = URLRequest(url: currentURL)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                return request
            }
            let json = try decodeJSON(response)
            let entries = json["value"] as? [[String: Any]] ?? []

            for entry in entries {
                guard let name = entry["name"] as? String else { continue }
                // Skip folders, return only files
                if entry["folder"] == nil {
                    allNames.append(name)
                }
            }

            // Handle pagination
            if let nextLink = json["@odata.nextLink"] as? String,
               let url = URL(string: nextLink) {
                nextURL = url
            } else {
                nextURL = nil
            }
        }

        return allNames
    }

    public func upload(data: Data, to path: String) async throws {
        // OneDrive auto-creates intermediate folders on PUT
        let url = graphURL(forContentAtPath: path)

        // A PUT writes the whole file at a fixed path, so repeating it leaves the same result
        let response = try await performAuthorized(body: data) { token in
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 3600
            return request
        }

        guard (200..<300).contains(response.statusCode) else {
            throw mapHTTPError(statusCode: response.statusCode)
        }
    }

    public func download(from path: String) async throws -> Data {
        let url = graphURL(forContentAtPath: path)

        let response = try await performAuthorized { token in
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 3600
            return request
        }

        if response.statusCode == 404 {
            throw CloudFileSystemError.fileNotFound
        }

        guard (200..<300).contains(response.statusCode) else {
            throw mapHTTPError(statusCode: response.statusCode)
        }

        return response.data
    }

    public func remove(at path: String) async throws {
        let url = graphURL(forItemAtPath: path)
        let response = try await performAuthorized { token in
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }

        // 204 No Content = success, 404 = already gone
        guard response.statusCode == 204 || response.statusCode == 404 else {
            throw mapHTTPError(statusCode: response.statusCode)
        }
    }

    public func removeDirectory(at path: String) async throws {
        // OneDrive DELETE on a folder removes it recursively
        try await remove(at: path)
    }

    // MARK: - URL Construction

    /// Returns the Graph API URL for a drive item at the given path.
    /// Uses the colon syntax: `/me/drive/root:/path/to/item:`
    func graphURL(forItemAtPath path: String) -> URL {
        let absPath = absolutePath(for: path)
        if absPath == "/" {
            return Self.graphBaseURL.appendingPathComponent("me/drive/root")
        }
        let encoded = encodePathForGraph(absPath)
        let urlString = "\(Self.graphBaseURL.absoluteString)/me/drive/root:\(encoded):"
        return URL(string: urlString)!
    }

    /// Returns the Graph API URL for listing children of a directory.
    func graphURL(forChildrenAtPath path: String) -> URL {
        let absPath = absolutePath(for: path)
        if absPath == "/" {
            return Self.graphBaseURL.appendingPathComponent("me/drive/root/children")
        }
        let encoded = encodePathForGraph(absPath)
        let urlString = "\(Self.graphBaseURL.absoluteString)/me/drive/root:\(encoded):/children"
        return URL(string: urlString)!
    }

    /// Returns the Graph API URL for uploading/downloading file content.
    func graphURL(forContentAtPath path: String) -> URL {
        let absPath = absolutePath(for: path)
        let encoded = encodePathForGraph(absPath)
        let urlString = "\(Self.graphBaseURL.absoluteString)/me/drive/root:\(encoded):/content"
        return URL(string: urlString)!
    }

    // MARK: - Path Helpers

    func absolutePath(for path: String) -> String {
        var absPath = path
        if !absPath.hasPrefix("/") { absPath = "/" + absPath }
        while absPath.contains("//") {
            absPath = absPath.replacingOccurrences(of: "//", with: "/")
        }
        if absPath != "/", absPath.hasSuffix("/") {
            absPath = String(absPath.dropLast())
        }
        return absPath
    }

    /// Percent-encodes a path for use in Graph API URLs.
    func encodePathForGraph(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        let encoded = components.map { component in
            component.addingPercentEncoding(withAllowedCharacters: .graphPathAllowed) ?? String(component)
        }
        return "/" + encoded.joined(separator: "/")
    }

    // MARK: - Request Helpers

    /// Sends an authorized request, and on a 401 gets a fresh token and sends it once more.
    ///
    /// The retry sits here, at one request, rather than around a whole operation. A listing that
    /// runs to several pages takes a fresh token per page, so a token that expires mid-listing
    /// costs one repeated page instead of the whole listing.
    ///
    /// - Parameters:
    ///   - makeRequest: Builds the request from a token. Called again with the new token on a retry.
    ///   - body: Data to upload, for a PUT or POST.
    ///   - isSafeToRepeat: Pass false when repeating the request could do the work twice.
    private func performAuthorized(
        body: Data? = nil,
        isSafeToRepeat: Bool = true,
        makeRequest: (String) -> URLRequest
    ) async throws -> HTTPClient.Response {
        let token = try await tokenProvider()
        let response = try await http.perform(prepared(makeRequest(token)), uploading: body, isSafeToRepeat: isSafeToRepeat)

        // A 401 usually means the token died in flight. Only a refreshable token is worth retrying
        guard response.statusCode == 401, let tokenRefresher else { return response }

        // Say which token was refused, so a refresh already running cannot answer with it
        let freshToken = try await tokenRefresher(token)
        return try await http.perform(prepared(makeRequest(freshToken)), uploading: body, isSafeToRepeat: isSafeToRepeat)
    }

    private func prepared(_ request: URLRequest) -> URLRequest {
        var req = request
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if req.timeoutInterval == 0 { req.timeoutInterval = 60 }
        return req
    }

    /// Turns a response into JSON, mapping the statuses this API uses onto `CloudFileSystemError`.
    private func decodeJSON(_ response: HTTPClient.Response) throws -> [String: Any] {
        if response.statusCode == 404 {
            throw CloudFileSystemError.fileNotFound
        }

        guard (200..<300).contains(response.statusCode) else {
            throw mapHTTPError(statusCode: response.statusCode)
        }

        return try parseJSON(response.data)
    }

    private func parseJSON(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudFileSystemError.serverError(statusCode: 0)
        }
        return json
    }

    // MARK: - Error Handling

    func mapHTTPError(statusCode: Int) -> CloudFileSystemError {
        switch statusCode {
        case 401: return .authenticationFailed
        case 404: return .fileNotFound
        default: return .serverError(statusCode: statusCode)
        }
    }
}

// MARK: - Character Set Extension

private extension CharacterSet {
    /// Characters allowed in OneDrive path components.
    /// Standard URL path-allowed characters minus colon, hash, and question mark
    /// (colon is used as the Graph API delimiter).
    static let graphPathAllowed: CharacterSet = {
        var cs = CharacterSet.urlPathAllowed
        cs.remove(charactersIn: ":#?")
        return cs
    }()
}
