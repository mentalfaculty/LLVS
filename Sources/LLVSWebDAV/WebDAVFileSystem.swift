//
//  WebDAVFileSystem.swift
//  LLVSWebDAV
//
//  Created by Drew McCormack on 03/03/2026.
//

import Foundation
import LLVS

/// A `CloudFileSystem` backed by a WebDAV server using `URLSession`.
///
/// No third-party dependencies — uses standard HTTP methods
/// (PROPFIND, MKCOL, PUT, GET, DELETE).
///
/// Authentication is handled via `URLCredential`, supporting both Basic and
/// Digest auth (Digest is handled automatically by URLSession's challenge mechanism).
public final class WebDAVFileSystem: CloudFileSystem, @unchecked Sendable {

    // MARK: - Properties

    /// The base URL of the WebDAV server.
    public let baseURL: URL

    /// The credential used for authentication.
    /// Set from the username and password at init. The session delegate answers challenges with it.
    public let credential: URLCredential?

    private let http: HTTPClient

    // MARK: - Initialization

    /// Creates a WebDAV file system with the given base URL.
    /// - Parameters:
    ///   - baseURL: The root URL of the WebDAV server.
    ///   - username: Optional username for authentication.
    ///   - password: Optional password for authentication.
    ///   - session: Pass your own to control networking. Mainly for tests. A supplied session gets no
    ///     credential delegate, so give it whatever authentication it needs itself.
    ///   - retryPolicy: How hard to try again when the server is busy or briefly broken.
    ///   - sleeper: Waits between attempts. Tests supply their own, so they do not really sleep.
    public init(baseURL: URL, username: String? = nil, password: String? = nil, session: URLSession? = nil, retryPolicy: HTTPClient.RetryPolicy = .default, sleeper: (any HTTPSleeper)? = nil) {
        self.baseURL = baseURL
        if let username, let password {
            self.credential = URLCredential(user: username, password: password, persistence: .forSession)
        } else {
            self.credential = nil
        }
        // A supplied session has no credential delegate, so it must carry its own authentication
        precondition(session == nil || (username == nil && password == nil),
                     "A supplied URLSession must carry its own authentication; do not also pass a username and password")
        let resolvedSession: URLSession
        if let session {
            resolvedSession = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 3600
            // The delegate answers the server's authentication challenge with the credential
            let delegate = SessionDelegate(credential: self.credential)
            resolvedSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        }
        self.http = HTTPClient(session: resolvedSession, policy: retryPolicy, sleeper: sleeper)
    }

    // MARK: - CloudFileSystem

    public func fileExists(at path: String) async throws -> Bool {
        let request = makePropfindRequest(forPath: path, depth: 0)
        let response = try await http.perform(request)
        if response.statusCode == 404 { return false }
        try checkHTTPResponse(statusCode: response.statusCode)
        return true
    }

    public func contentsOfDirectory(at path: String) async throws -> [String] {
        var dirPath = path
        if !dirPath.hasSuffix("/") { dirPath += "/" }

        let request = makePropfindRequest(forPath: dirPath, depth: 1)
        let response = try await http.perform(request)

        if response.statusCode == 404 {
            throw CloudFileSystemError.fileNotFound
        }
        try checkHTTPResponse(statusCode: response.statusCode)

        let parser = WebDAVResponseParser(data: response.data)
        try parser.parse()

        // The first item is the directory itself — skip it
        var items = parser.parsedItems
        if items.count > 1 {
            items = Array(items.dropFirst())
        } else {
            items = []
        }

        // Return only file names (not directories)
        return items.filter { !$0.isDirectory }.map { $0.name }
    }

    public func upload(data: Data, to path: String) async throws {
        // Create intermediate directories
        try await createIntermediateDirectories(for: path)

        var request = makeRequest(forPath: path)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        request.timeoutInterval = 3600

        // A PUT writes the whole file at a fixed path, so repeating it leaves the same result
        let response = try await http.perform(request, uploading: data)
        try checkHTTPResponse(statusCode: response.statusCode)
    }

    public func download(from path: String) async throws -> Data {
        var request = makeRequest(forPath: path)
        request.httpMethod = "GET"

        let response = try await http.perform(request)

        if response.statusCode == 404 {
            throw CloudFileSystemError.fileNotFound
        }
        try checkHTTPResponse(statusCode: response.statusCode)
        return response.data
    }

    public func remove(at path: String) async throws {
        var request = makeRequest(forPath: path)
        request.httpMethod = "DELETE"

        let response = try await http.perform(request)

        // 404 means already gone — not an error
        if response.statusCode == 404 { return }
        try checkHTTPResponse(statusCode: response.statusCode)
    }

    public func removeDirectory(at path: String) async throws {
        // WebDAV DELETE on a collection removes it recursively
        var dirPath = path
        if !dirPath.hasSuffix("/") { dirPath += "/" }

        var request = makeRequest(forPath: dirPath)
        request.httpMethod = "DELETE"

        let response = try await http.perform(request)

        // 404 means already gone — not an error
        if response.statusCode == 404 { return }
        try checkHTTPResponse(statusCode: response.statusCode)
    }

    // MARK: - Directory Creation

    private func createIntermediateDirectories(for path: String) async throws {
        let components = path.split(separator: "/").dropLast() // drop the filename
        var currentPath = ""
        for component in components {
            currentPath += "/\(component)"
            // Check if directory exists
            let request = makePropfindRequest(forPath: currentPath + "/", depth: 0)
            let response = try await http.perform(request)

            if response.statusCode == 404 {
                // Create the directory
                var mkcolRequest = makeRequest(forPath: currentPath)
                mkcolRequest.httpMethod = "MKCOL"
                mkcolRequest.setValue("application/xml", forHTTPHeaderField: "Content-Type")
                let mkcolResponse = try await http.perform(mkcolRequest)
                // 405 Method Not Allowed means the directory already exists, and a retry that
                // followed a lost reply would see exactly that
                if mkcolResponse.statusCode != 405 {
                    try checkHTTPResponse(statusCode: mkcolResponse.statusCode)
                }
            }
        }
    }

    // MARK: - Request Building

    private func makeRequest(forPath path: String) -> URLRequest {
        let url = baseURL.appendingPathComponent(path)
        return URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
    }

    private func makePropfindRequest(forPath path: String, depth: Int) -> URLRequest {
        var request = makeRequest(forPath: path)
        request.httpMethod = "PROPFIND"
        request.setValue("\(depth)", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")

        let xml = """
        <?xml version="1.0" encoding="utf-8" ?>\
        <D:propfind xmlns:D="DAV:">\
        <D:prop>\
        <D:resourcetype/>\
        <D:getcontentlength/>\
        </D:prop>\
        </D:propfind>
        """
        request.httpBody = xml.data(using: .utf8)
        return request
    }

    // MARK: - Response Handling

    private func checkHTTPResponse(statusCode: Int) throws {
        if statusCode == 401 {
            throw CloudFileSystemError.authenticationFailed
        }
        guard (200..<300).contains(statusCode) || statusCode == 207 else {
            throw CloudFileSystemError.serverError(statusCode: statusCode)
        }
    }
}

// MARK: - URLSession Delegate for Authentication

private final class SessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {

    private let credential: URLCredential?

    init(credential: URLCredential?) {
        self.credential = credential
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let protectionSpace = challenge.protectionSpace

        if protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ||
           protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        if let credential, challenge.previousFailureCount == 0 {
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
