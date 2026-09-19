//
//  GoogleDriveFileSystem.swift
//  LLVSGoogleDrive
//
//  Created by Drew McCormack on 03/03/2026.
//

import Foundation
import LLVS

/// A `CloudFileSystem` backed by the Google Drive REST API v3 using `URLSession`.
///
/// Google Drive uses file IDs rather than paths to identify files and folders.
/// This backend bridges the path-based `CloudFileSystem` protocol onto Google Drive's
/// ID-based API by walking the folder hierarchy to resolve paths to IDs.
///
/// Resolved IDs are cached to minimize API calls. The cache is invalidated
/// when items are deleted.
///
/// Two initialization paths are available:
/// ```swift
/// // Static access token (app manages refresh externally)
/// let fs = GoogleDriveFileSystem(accessToken: "your-token")
///
/// // Authenticator with auto-refresh
/// let fs = GoogleDriveFileSystem(authenticator: authenticator)
/// ```
public final class GoogleDriveFileSystem: CloudFileSystem, @unchecked Sendable {

    // MARK: - Properties

    private let tokenProvider: @Sendable () async throws -> String

    /// Cache mapping absolute paths to Google Drive folder IDs.
    private var folderIDCache: [String: String] = ["/": "root"]

    /// Cache mapping absolute file paths to Google Drive file IDs.
    private var fileIDCache: [String: String] = [:]

    private static let apiBaseURL = URL(string: "https://www.googleapis.com/drive/v3/")!
    private static let uploadBaseURL = URL(string: "https://www.googleapis.com/upload/drive/v3/")!
    private static let folderMimeType = "application/vnd.google-apps.folder"

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

    /// Creates a Google Drive file system with a static access token.
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

    /// Creates a Google Drive file system with an authenticator that
    /// automatically refreshes expired tokens.
    /// - Parameters:
    ///   - session: Pass your own to control networking. Mainly for tests.
    ///   - retryPolicy: How hard to try again when the server is busy or briefly broken.
    ///   - sleeper: Waits between attempts. Tests supply their own, so they do not really sleep.
    public init(authenticator: GoogleDriveAuthenticator, session: URLSession? = nil, retryPolicy: HTTPClient.RetryPolicy = .default, sleeper: (any HTTPSleeper)? = nil) {
        self.tokenProvider = { try await authenticator.validAccessToken() }
        self.tokenRefresher = { staleToken in try await authenticator.freshAccessToken(replacing: staleToken) }
        self.http = HTTPClient(session: session ?? Self.makeDefaultSession(), policy: retryPolicy, sleeper: sleeper)
    }

    // MARK: - CloudFileSystem

    public func fileExists(at path: String) async throws -> Bool {
        let absPath = absolutePath(for: path)
        let parentPath = (absPath as NSString).deletingLastPathComponent
        let name = (absPath as NSString).lastPathComponent

        do {
            let parentID = try await resolveFolderID(forPath: parentPath)

            // Check for folder
            let folderQuery = "'\(parentID)' in parents and name='\(escapedQuery(name))' and mimeType='\(Self.folderMimeType)' and trashed=false"
            let folderResult = try await queryFiles(query: folderQuery, fields: "files(id)")
            if !folderResult.isEmpty { return true }

            // Check for file
            let fileQuery = "'\(parentID)' in parents and name='\(escapedQuery(name))' and trashed=false"
            let fileResult = try await queryFiles(query: fileQuery, fields: "files(id)")
            return !fileResult.isEmpty
        } catch {
            if isNotFoundError(error) { return false }
            throw error
        }
    }

    public func contentsOfDirectory(at path: String) async throws -> [String] {
        let absPath = absolutePath(for: path)
        let folderID: String
        do {
            folderID = try await resolveFolderID(forPath: absPath)
        } catch {
            if isNotFoundError(error) { throw CloudFileSystemError.fileNotFound }
            throw error
        }

        var allNames: [String] = []
        var pageToken: String? = nil

        repeat {
            let query = "'\(folderID)' in parents and trashed=false"
            var params: [String: String] = [
                "q": query,
                "fields": "nextPageToken,files(id,name,mimeType)",
                "pageSize": "1000"
            ]
            if let pageToken { params["pageToken"] = pageToken }

            let url = urlWithQuery(Self.apiBaseURL.appendingPathComponent("files"), params: params)
            let response = try await performAuthorized { token in
                var request = URLRequest(url: url)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                return request
            }
            let json = try decodeJSON(response)
            let files = json["files"] as? [[String: Any]] ?? []

            for entry in files {
                guard let name = entry["name"] as? String else { continue }
                let mimeType = entry["mimeType"] as? String ?? ""
                let entryPath = (absPath as NSString).appendingPathComponent(name)

                if mimeType == Self.folderMimeType {
                    if let id = entry["id"] as? String {
                        folderIDCache[entryPath] = id
                    }
                    // Don't include directories in the list
                } else {
                    if let id = entry["id"] as? String {
                        fileIDCache[entryPath] = id
                    }
                    allNames.append(name)
                }
            }

            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil

        return allNames
    }

    public func upload(data: Data, to path: String) async throws {
        let absPath = absolutePath(for: path)
        let parentPath = (absPath as NSString).deletingLastPathComponent
        let fileName = (absPath as NSString).lastPathComponent

        // Create intermediate directories
        let parentID = try await createIntermediateDirectories(forPath: parentPath)

        // Delete existing file if present
        if let existingID = fileIDCache[absPath] {
            try? await deleteItem(withID: existingID)
            fileIDCache.removeValue(forKey: absPath)
        } else if let existingID = try? await resolveFileID(forPath: absPath) {
            try? await deleteItem(withID: existingID)
            fileIDCache.removeValue(forKey: absPath)
        }

        // Upload using multipart
        let metadata: [String: Any] = [
            "name": fileName,
            "parents": [parentID]
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata)

        let boundary = UUID().uuidString

        var url = Self.uploadBaseURL.appendingPathComponent("files")
        url = urlWithQuery(url, params: ["uploadType": "multipart", "fields": "id"])

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metadataData)
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        // This POST creates a new file with a new ID every time. A retry after a reply went missing
        // would leave two copies of the same path, so it is sent once and once only
        let response = try await performAuthorized(body: body, isSafeToRepeat: false) { token in
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 3600
            return request
        }

        guard (200..<300).contains(response.statusCode) else {
            throw mapHTTPError(statusCode: response.statusCode)
        }

        let json = try parseJSON(response.data)
        if let fileID = json["id"] as? String {
            fileIDCache[absPath] = fileID
        }
    }

    public func download(from path: String) async throws -> Data {
        let absPath = absolutePath(for: path)
        let fileID = try await resolveFileID(forPath: absPath)

        let url = urlWithQuery(
            Self.apiBaseURL.appendingPathComponent("files/\(fileID)"),
            params: ["alt": "media"]
        )
        let response = try await performAuthorized { token in
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 3600
            return request
        }

        guard (200..<300).contains(response.statusCode) else {
            throw mapHTTPError(statusCode: response.statusCode)
        }

        return response.data
    }

    public func remove(at path: String) async throws {
        let absPath = absolutePath(for: path)

        // Try as file
        if let fileID = try? await resolveFileID(forPath: absPath) {
            try await deleteItem(withID: fileID)
            fileIDCache.removeValue(forKey: absPath)
            return
        }

        // 404-equivalent: not an error for remove
    }

    public func removeDirectory(at path: String) async throws {
        let absPath = absolutePath(for: path)

        // Try as folder
        var folderID = folderIDCache[absPath]
        if folderID == nil {
            folderID = try? await resolveFolderIDFromAPI(forPath: absPath)
        }
        if let folderID {
            try await deleteItem(withID: folderID)
            // Invalidate cache for this path and any children
            folderIDCache = folderIDCache.filter { !$0.key.hasPrefix(absPath) || $0.key == "/" }
            fileIDCache = fileIDCache.filter { !$0.key.hasPrefix(absPath) }
        }
    }

    // MARK: - Directory Creation

    /// Creates all intermediate directories for the given path, returning the ID of the deepest folder.
    private func createIntermediateDirectories(forPath path: String) async throws -> String {
        let absPath = absolutePath(for: path)
        let components = pathComponents(for: absPath)
        var currentPath = "/"
        var currentID = "root"

        for component in components {
            let nextPath = (currentPath as NSString).appendingPathComponent(component)

            if let cached = folderIDCache[nextPath] {
                currentID = cached
                currentPath = nextPath
                continue
            }

            // Check if folder exists
            let query = "'\(currentID)' in parents and name='\(escapedQuery(component))' and mimeType='\(Self.folderMimeType)' and trashed=false"
            let existing = try await queryFiles(query: query, fields: "files(id)")

            if let existingFolder = (existing.first as? [String: Any]),
               let existingID = existingFolder["id"] as? String {
                currentID = existingID
                folderIDCache[nextPath] = currentID
                currentPath = nextPath
                continue
            }

            // Create the folder
            let metadata: [String: Any] = [
                "name": component,
                "mimeType": Self.folderMimeType,
                "parents": [currentID]
            ]

            let metadataBody = try JSONSerialization.data(withJSONObject: metadata)
            let url = Self.apiBaseURL.appendingPathComponent("files")

            // Creating a folder makes a new one each time, so a retry would leave two folders of
            // the same name and later lookups could pick either
            let response = try await performAuthorized(body: metadataBody, isSafeToRepeat: false) { token in
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                return request
            }

            let json = try decodeJSON(response)
            if let folderID = json["id"] as? String {
                currentID = folderID
                folderIDCache[nextPath] = currentID
            }
            currentPath = nextPath
        }

        return currentID
    }

    // MARK: - Path Resolution

    private func resolveFolderID(forPath path: String) async throws -> String {
        let absPath = absolutePath(for: path)
        if let cached = folderIDCache[absPath] { return cached }

        let components = pathComponents(for: absPath)
        var currentPath = "/"
        var currentID = "root"

        for component in components {
            let nextPath = (currentPath as NSString).appendingPathComponent(component)

            if let cached = folderIDCache[nextPath] {
                currentID = cached
                currentPath = nextPath
                continue
            }

            let query = "'\(currentID)' in parents and name='\(escapedQuery(component))' and mimeType='\(Self.folderMimeType)' and trashed=false"
            let results = try await queryFiles(query: query, fields: "files(id,name)")

            guard let folder = results.first as? [String: Any],
                  let folderID = folder["id"] as? String else {
                throw CloudFileSystemError.fileNotFound
            }

            currentID = folderID
            folderIDCache[nextPath] = currentID
            currentPath = nextPath
        }

        return currentID
    }

    private func resolveFolderIDFromAPI(forPath path: String) async throws -> String {
        let absPath = absolutePath(for: path)
        let parentPath = (absPath as NSString).deletingLastPathComponent
        let name = (absPath as NSString).lastPathComponent

        let parentID = try await resolveFolderID(forPath: parentPath)
        let query = "'\(parentID)' in parents and name='\(escapedQuery(name))' and mimeType='\(Self.folderMimeType)' and trashed=false"
        let results = try await queryFiles(query: query, fields: "files(id)")

        guard let folder = results.first as? [String: Any],
              let folderID = folder["id"] as? String else {
            throw CloudFileSystemError.fileNotFound
        }

        folderIDCache[absPath] = folderID
        return folderID
    }

    private func resolveFileID(forPath path: String) async throws -> String {
        let absPath = absolutePath(for: path)
        if let cached = fileIDCache[absPath] { return cached }

        let parentPath = (absPath as NSString).deletingLastPathComponent
        let fileName = (absPath as NSString).lastPathComponent

        let parentID = try await resolveFolderID(forPath: parentPath)
        let query = "'\(parentID)' in parents and name='\(escapedQuery(fileName))' and trashed=false"
        let results = try await queryFiles(query: query, fields: "files(id,name)")

        guard let file = results.first as? [String: Any],
              let fileID = file["id"] as? String else {
            throw CloudFileSystemError.fileNotFound
        }

        fileIDCache[absPath] = fileID
        return fileID
    }

    // MARK: - API Helpers

    private func queryFiles(query: String, fields: String) async throws -> [Any] {
        let url = urlWithQuery(Self.apiBaseURL.appendingPathComponent("files"), params: [
            "q": query,
            "fields": fields
        ])
        let response = try await performAuthorized { token in
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }

        let json = try decodeJSON(response)
        return json["files"] as? [Any] ?? []
    }

    private func deleteItem(withID itemID: String) async throws {
        let url = Self.apiBaseURL.appendingPathComponent("files/\(itemID)")
        let response = try await performAuthorized { token in
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }

        // 204 No Content = success, 404 = already deleted, and a retry of a delete that got
        // through would see exactly that
        guard response.statusCode == 204 || response.statusCode == 404 else {
            throw mapHTTPError(statusCode: response.statusCode)
        }
    }

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

    func pathComponents(for path: String) -> [String] {
        absolutePath(for: path).split(separator: "/").map(String.init)
    }

    private func escapedQuery(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "\\'")
    }

    private func urlWithQuery(_ url: URL, params: [String: String]) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    // MARK: - Error Handling

    private func isNotFoundError(_ error: any Error) -> Bool {
        if let cfsError = error as? CloudFileSystemError {
            if case .fileNotFound = cfsError { return true }
        }
        return false
    }

    func mapHTTPError(statusCode: Int) -> CloudFileSystemError {
        switch statusCode {
        case 401: return .authenticationFailed
        case 404: return .fileNotFound
        default: return .serverError(statusCode: statusCode)
        }
    }
}
