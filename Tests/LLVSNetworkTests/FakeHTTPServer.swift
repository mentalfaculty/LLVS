import Foundation

/// A stand-in web server. Tests give it replies; it records the requests it was asked to make.
/// It is installed by making a `URLSession` from `FakeHTTPServer.makeSession()`.
final class FakeHTTPServer: @unchecked Sendable {

    struct Reply {
        var statusCode: Int = 200
        var body: Data = Data()
        var headers: [String: String] = [:]
        var error: (any Swift.Error)? = nil
    }

    struct RecordedRequest {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data?
    }

    private let lock = NSLock()
    private var replies: [Reply] = []
    private var recorded: [RecordedRequest] = []

    /// Replies are handed out in order. The last one repeats once the list runs out.
    func setReplies(_ replies: [Reply]) {
        lock.withLock { self.replies = replies }
    }

    var requests: [RecordedRequest] { lock.withLock { recorded } }
    var requestCount: Int { lock.withLock { recorded.count } }

    fileprivate func nextReply(for request: RecordedRequest) -> Reply {
        lock.withLock {
            recorded.append(request)
            guard !replies.isEmpty else { return Reply() }
            return replies.count == 1 ? replies[0] : replies.removeFirst()
        }
    }

    func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        // The server is found again by this token, because URLProtocol gets the request, not the session
        let token = FakeURLProtocol.register(self)
        configuration.protocolClasses = [FakeURLProtocol.self]
        configuration.httpAdditionalHeaders = [FakeURLProtocol.serverTokenHeader: token]
        return URLSession(configuration: configuration)
    }
}

/// Routes requests to the `FakeHTTPServer` registered for the session that made them.
final class FakeURLProtocol: URLProtocol, @unchecked Sendable {

    static let serverTokenHeader = "X-Fake-Server-Token"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var serversByToken: [String: FakeHTTPServer] = [:]

    static func register(_ server: FakeHTTPServer) -> String {
        let token = UUID().uuidString
        lock.withLock { serversByToken[token] = server }
        return token
    }

    private static func server(for request: URLRequest) -> FakeHTTPServer? {
        guard let token = request.value(forHTTPHeaderField: serverTokenHeader) else { return nil }
        return lock.withLock { serversByToken[token] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let server = Self.server(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        // URLProtocol strips the body into a stream, so read it back
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var collected = Data()
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: bufferSize)
                if read <= 0 { break }
                collected.append(contentsOf: buffer[0..<read])
            }
            body = collected
        }

        let recorded = FakeHTTPServer.RecordedRequest(
            method: request.httpMethod ?? "GET",
            url: url,
            headers: request.allHTTPHeaderFields ?? [:],
            body: body
        )
        let reply = server.nextReply(for: recorded)

        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.statusCode, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
