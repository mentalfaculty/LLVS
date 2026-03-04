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

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config)
    }()

    // MARK: - Initialization

    /// Creates a OneDrive file system with a static access token.
    public init(accessToken: String) {
        self.tokenProvider = { accessToken }
    }

    /// Creates a OneDrive file system with an authenticator that
    /// automatically refreshes expired tokens.
    public init(authenticator: OneDriveAuthenticator) {
        self.tokenProvider = { try await authenticator.validAccessToken() }
    }

    // MARK: - CloudFileSystem

    public func fileExists(at path: String) async throws -> Bool {
        let token = try await tokenProvider()
        let url = graphURL(forItemAtPath: path)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        if statusCode == 404 { return false }
        if (200..<300).contains(statusCode) { return true }
        throw mapHTTPError(statusCode: statusCode)
    }

    public func contentsOfDirectory(at path: String) async throws -> [String] {
        let absPath = absolutePath(for: path)
        var allNames: [String] = []
        var nextURL: URL? = graphURL(forChildrenAtPath: absPath)

        while let currentURL = nextURL {
            let token = try await tokenProvider()
            var request = URLRequest(url: currentURL)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let json = try await performRequest(request)
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
        let token = try await tokenProvider()
        let url = graphURL(forContentAtPath: path)

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3600

        let (_, response) = try await session.upload(for: request, from: data)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200..<300).contains(statusCode) else {
            throw mapHTTPError(statusCode: statusCode)
        }
    }

    public func download(from path: String) async throws -> Data {
        let token = try await tokenProvider()
        let url = graphURL(forContentAtPath: path)

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 3600

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        if statusCode == 404 {
            throw CloudFileSystemError.fileNotFound
        }

        guard (200..<300).contains(statusCode) else {
            throw mapHTTPError(statusCode: statusCode)
        }

        return data
    }

    public func remove(at path: String) async throws {
        let token = try await tokenProvider()
        let url = graphURL(forItemAtPath: path)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        // 204 No Content = success, 404 = already gone
        guard statusCode == 204 || statusCode == 404 else {
            throw mapHTTPError(statusCode: statusCode)
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

    private func performRequest(_ request: URLRequest) async throws -> [String: Any] {
        var req = request
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if req.timeoutInterval == 0 { req.timeoutInterval = 60 }

        let (data, response) = try await session.data(for: req)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        if statusCode == 404 {
            throw CloudFileSystemError.fileNotFound
        }

        guard (200..<300).contains(statusCode) else {
            throw mapHTTPError(statusCode: statusCode)
        }

        return try parseJSON(data)
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
