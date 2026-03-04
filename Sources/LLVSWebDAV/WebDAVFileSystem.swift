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
    public var credential: URLCredential?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        let delegate = SessionDelegate(fileSystem: self)
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    // MARK: - Initialization

    /// Creates a WebDAV file system with the given base URL.
    /// - Parameters:
    ///   - baseURL: The root URL of the WebDAV server.
    ///   - username: Optional username for authentication.
    ///   - password: Optional password for authentication.
    public init(baseURL: URL, username: String? = nil, password: String? = nil) {
        self.baseURL = baseURL
        if let username, let password {
            self.credential = URLCredential(user: username, password: password, persistence: .forSession)
        }
    }

    // MARK: - CloudFileSystem

    public func fileExists(at path: String) async throws -> Bool {
        let request = makePropfindRequest(forPath: path, depth: 0)
        let (_, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        if statusCode == 404 { return false }
        try checkHTTPResponse(statusCode: statusCode)
        return true
    }

    public func contentsOfDirectory(at path: String) async throws -> [String] {
        var dirPath = path
        if !dirPath.hasSuffix("/") { dirPath += "/" }

        let request = makePropfindRequest(forPath: dirPath, depth: 1)
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        if statusCode == 404 {
            throw CloudFileSystemError.fileNotFound
        }
        try checkHTTPResponse(statusCode: statusCode)

        let parser = WebDAVResponseParser(data: data)
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

        let (_, response) = try await session.upload(for: request, from: data)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        try checkHTTPResponse(statusCode: statusCode)
    }

    public func download(from path: String) async throws -> Data {
        var request = makeRequest(forPath: path)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        if statusCode == 404 {
            throw CloudFileSystemError.fileNotFound
        }
        try checkHTTPResponse(statusCode: statusCode)
        return data
    }

    public func remove(at path: String) async throws {
        var request = makeRequest(forPath: path)
        request.httpMethod = "DELETE"

        let (_, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        // 404 means already gone — not an error
        if statusCode == 404 { return }
        try checkHTTPResponse(statusCode: statusCode)
    }

    public func removeDirectory(at path: String) async throws {
        // WebDAV DELETE on a collection removes it recursively
        var dirPath = path
        if !dirPath.hasSuffix("/") { dirPath += "/" }

        var request = makeRequest(forPath: dirPath)
        request.httpMethod = "DELETE"

        let (_, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        // 404 means already gone — not an error
        if statusCode == 404 { return }
        try checkHTTPResponse(statusCode: statusCode)
    }

    // MARK: - Directory Creation

    private func createIntermediateDirectories(for path: String) async throws {
        let components = path.split(separator: "/").dropLast() // drop the filename
        var currentPath = ""
        for component in components {
            currentPath += "/\(component)"
            // Check if directory exists
            let request = makePropfindRequest(forPath: currentPath + "/", depth: 0)
            let (_, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            if statusCode == 404 {
                // Create the directory
                var mkcolRequest = makeRequest(forPath: currentPath)
                mkcolRequest.httpMethod = "MKCOL"
                mkcolRequest.setValue("application/xml", forHTTPHeaderField: "Content-Type")
                let (_, mkcolResponse) = try await session.data(for: mkcolRequest)
                let mkcolStatus = (mkcolResponse as? HTTPURLResponse)?.statusCode ?? 0
                // 405 Method Not Allowed means the directory already exists
                if mkcolStatus != 405 {
                    try checkHTTPResponse(statusCode: mkcolStatus)
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
        <D:href/>\
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

    weak var fileSystem: WebDAVFileSystem?

    init(fileSystem: WebDAVFileSystem) {
        self.fileSystem = fileSystem
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let protectionSpace = challenge.protectionSpace

        if protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ||
           protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        if let credential = fileSystem?.credential, challenge.previousFailureCount == 0 {
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
