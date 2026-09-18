//
//  HTTPClient.swift
//  LLVS
//
//  Created by Drew McCormack on 18/09/2026.
//

import Foundation

/// Waits between attempts. Tests supply their own, so they do not really sleep.
public protocol HTTPSleeper: Sendable {
    func sleep(for seconds: TimeInterval) async throws
}

struct TaskSleeper: HTTPSleeper {
    func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

/// Makes HTTP requests, and retries the ones that are worth retrying.
///
/// It does not interpret status codes beyond deciding whether to try again: a 404 or a 403 comes back
/// to the caller as a response, not an error, because what those mean differs per service. Only a
/// transport failure, such as a dropped connection, is thrown.
public struct HTTPClient: Sendable {

    public struct Response: Sendable {
        public let data: Data
        public let statusCode: Int
        public let headerFields: [String: String]

        public init(data: Data, statusCode: Int, headerFields: [String: String] = [:]) {
            self.data = data
            self.statusCode = statusCode
            self.headerFields = headerFields
        }

        init(data: Data, response: HTTPURLResponse) {
            self.data = data
            self.statusCode = response.statusCode
            self.headerFields = response.allHeaderFields.reduce(into: [:]) { result, pair in
                if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
            }
        }

        /// Throws unless the status is a success, or one the caller says is fine.
        /// Use it for the codes a service treats as normal, such as WebDAV's 207, or its 405 for
        /// a directory that already exists.
        public func requireSuccess(allowing acceptableStatusCodes: Set<Int> = []) throws {
            let isAcceptable = (200..<300).contains(statusCode) || acceptableStatusCodes.contains(statusCode)
            guard !isAcceptable else { return }
            throw StatusError(statusCode: statusCode, body: data)
        }

        /// The value of a header, whatever case the server used for its name.
        public func headerValue(for name: String) -> String? {
            headerFields.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    /// A status the caller did not expect. It keeps the body, because servers explain themselves there.
    public struct StatusError: Swift.Error, Sendable {
        public let statusCode: Int
        public let body: Data

        public var bodyText: String? { String(data: body, encoding: .utf8) }
    }

    public struct RetryPolicy: Sendable {
        /// How many extra attempts to make after the first one fails.
        public var maximumRetries: Int
        /// The wait before the first retry. It doubles each time, up to `maximumDelay`.
        public var initialDelay: TimeInterval
        public var maximumDelay: TimeInterval

        public init(maximumRetries: Int = 3, initialDelay: TimeInterval = 0.5, maximumDelay: TimeInterval = 30) {
            self.maximumRetries = maximumRetries
            self.initialDelay = initialDelay
            self.maximumDelay = maximumDelay
        }

        public static let `default` = RetryPolicy()
        public static let none = RetryPolicy(maximumRetries: 0)
    }

    private let session: URLSession
    private let sleeper: any HTTPSleeper
    private let policy: RetryPolicy

    public init(session: URLSession, policy: RetryPolicy = .default, sleeper: (any HTTPSleeper)? = nil) {
        self.session = session
        self.policy = policy
        self.sleeper = sleeper ?? TaskSleeper()
    }

    /// Performs the request, retrying while the server says it is busy or broken.
    ///
    /// - Parameters:
    ///   - request: The request to make.
    ///   - body: Data to upload, for a PUT or POST.
    ///   - isSafeToRepeat: Pass false when repeating the request could do the work twice. An upload
    ///     that creates a new file each time is not safe to repeat, because a retry after a timeout
    ///     would leave two copies.
    /// - Returns: The last response received, whatever its status code.
    /// - Throws: The transport error, if every attempt failed to reach the server at all.
    public func perform(_ request: URLRequest, uploading body: Data? = nil, isSafeToRepeat: Bool = true) async throws -> Response {
        let attempts = isSafeToRepeat ? policy.maximumRetries : 0
        var delay = policy.initialDelay

        for attempt in 0...attempts {
            try Task.checkCancellation()
            do {
                let (data, urlResponse) = try await send(request, uploading: body)
                guard let http = urlResponse as? HTTPURLResponse else {
                    return Response(data: data, statusCode: 200)
                }
                let response = Response(data: data, response: http)
                guard attempt < attempts, isWorthRetrying(status: http.statusCode) else { return response }

                // A server that says how long to wait knows better than the doubling, but it does not
                // get to hold the sync open for a day, and a broken one can send nonsense
                let asked = response.headerValue(for: "Retry-After").flatMap(Self.secondsToWait(fromRetryAfter:))
                try await sleeper.sleep(for: min(asked ?? delay, policy.maximumDelay))
                delay = min(delay * 2, policy.maximumDelay)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                guard isWorthRetrying(error: error), attempt < attempts else { throw error }
                try await sleeper.sleep(for: delay)
                delay = min(delay * 2, policy.maximumDelay)
            }
        }

        // The last attempt always returns or throws above
        preconditionFailure("The retry loop ended without a result")
    }

    private func send(_ request: URLRequest, uploading body: Data?) async throws -> (Data, URLResponse) {
        if let body {
            return try await session.upload(for: request, from: body)
        } else {
            return try await session.data(for: request)
        }
    }

    /// Retry while the problem is likely to be temporary: the server is busy, or briefly broken.
    /// A 4xx means the request itself is wrong, so repeating it would give the same answer.
    private func isWorthRetrying(status: Int) -> Bool {
        status == 408 || status == 429 || (500...599).contains(status)
    }

    private func isWorthRetrying(error: any Swift.Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .resourceUnavailable, .internationalRoamingOff,
             .callIsActive, .dataNotAllowed, .badServerResponse, .cannotLoadFromNetwork:
            return true
        default:
            return false
        }
    }

    /// `Retry-After` is either a number of seconds, or an HTTP date.
    static func secondsToWait(fromRetryAfter value: String) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let seconds = TimeInterval(trimmed) {
            guard seconds.isFinite else { return nil }
            return max(0, seconds)
        }

        guard let date = httpDateFormatter.date(from: trimmed) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}

/// RFC 7231 IMF-fixdate, the form every current server sends. The two legacy forms fall back to the
/// doubling delay, which is a safe answer rather than a wrong one.
private let httpDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter
}()
