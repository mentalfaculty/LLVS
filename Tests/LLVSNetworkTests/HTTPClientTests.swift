import Testing
import Foundation
@testable import LLVS

@Suite struct HTTPClientTests {

    private func client(_ server: FakeHTTPServer, clock: TestSleeper = TestSleeper()) -> HTTPClient {
        HTTPClient(session: server.makeSession(), sleeper: clock)
    }

    private var request: URLRequest { URLRequest(url: URL(string: "https://example.com/thing")!) }

    @Test func aSuccessfulRequestIsMadeOnce() async throws {
        let server = FakeHTTPServer()
        server.setReplies([.init(statusCode: 200, body: Data("hi".utf8))])

        let response = try await client(server).perform(request)

        #expect(String(data: response.data, encoding: .utf8) == "hi")
        #expect(server.requestCount == 1)
    }

    @Test func serverErrorsAreRetriedThenGiveUp() async throws {
        let server = FakeHTTPServer()
        server.setReplies([.init(statusCode: 503)])
        let sleeper = TestSleeper()

        let response = try await client(server, clock: sleeper).perform(request)

        #expect(response.statusCode == 503)
        #expect(server.requestCount == 4) // the first try, then three retries
        #expect(sleeper.sleeps.count == 3)
    }

    @Test func aRetryThatSucceedsReturnsTheGoodResponse() async throws {
        let server = FakeHTTPServer()
        server.setReplies([.init(statusCode: 500), .init(statusCode: 200, body: Data("ok".utf8))])

        let response = try await client(server).perform(request)

        #expect(response.statusCode == 200)
        #expect(server.requestCount == 2)
    }

    @Test func waitsGetLongerEachTime() async throws {
        let server = FakeHTTPServer()
        server.setReplies([.init(statusCode: 500)])
        let sleeper = TestSleeper()

        _ = try await client(server, clock: sleeper).perform(request)

        #expect(sleeper.sleeps == sorted(sleeper.sleeps), "each wait should be at least as long as the one before")
        #expect(sleeper.sleeps.first! >= 0.1)
    }

    @Test func tooManyRequestsWaitsTheTimeTheServerAsksFor() async throws {
        let server = FakeHTTPServer()
        server.setReplies([.init(statusCode: 429, headers: ["Retry-After": "7"]), .init(statusCode: 200)])
        let sleeper = TestSleeper()

        _ = try await client(server, clock: sleeper).perform(request)

        #expect(sleeper.sleeps == [7.0])
    }

    @Test func clientErrorsAreNotRetried() async throws {
        let server = FakeHTTPServer()
        server.setReplies([.init(statusCode: 404)])

        let response = try await client(server).perform(request)

        #expect(response.statusCode == 404)
        #expect(server.requestCount == 1)
    }

    @Test func aDroppedConnectionIsRetried() async throws {
        let server = FakeHTTPServer()
        server.setReplies([.init(error: URLError(.networkConnectionLost)), .init(statusCode: 200)])

        let response = try await client(server).perform(request)

        #expect(response.statusCode == 200)
        #expect(server.requestCount == 2)
    }

    @Test func aRequestThatMustNotRepeatIsTriedOnce() async throws {
        // A Google Drive upload creates a new file each time, so a retry would leave duplicates
        let server = FakeHTTPServer()
        server.setReplies([.init(statusCode: 503)])

        let response = try await client(server).perform(request, isSafeToRepeat: false)

        #expect(response.statusCode == 503)
        #expect(server.requestCount == 1)
    }

    @Test func aHugeRetryAfterIsCappedByThePolicy() async throws {
        // A server could ask us to wait a day, or send nonsense that parses as infinity
        let server = FakeHTTPServer()
        server.setReplies([.init(statusCode: 429, headers: ["Retry-After": "86400"]), .init(statusCode: 200)])
        let sleeper = TestSleeper()

        _ = try await client(server, clock: sleeper).perform(request)

        #expect(sleeper.sleeps == [30.0]) // the policy maximum
    }

    @Test func anInfiniteRetryAfterIsIgnored() async throws {
        let server = FakeHTTPServer()
        server.setReplies([.init(statusCode: 429, headers: ["Retry-After": "inf"]), .init(statusCode: 200)])
        let sleeper = TestSleeper()

        _ = try await client(server, clock: sleeper).perform(request)

        #expect(sleeper.sleeps.first.map { $0.isFinite } == true)
    }

    @Test func aCancelledRequestThrowsCancellation() async throws {
        // URLSession reports cancellation as URLError(.cancelled), not CancellationError
        let server = FakeHTTPServer()
        server.setReplies([.init(error: URLError(.cancelled))])

        await #expect(throws: CancellationError.self) {
            _ = try await self.client(server).perform(self.request)
        }
        #expect(server.requestCount == 1)
    }

    @Test func cancellationStopsTheRetries() async throws {
        let server = FakeHTTPServer()
        server.setReplies([.init(statusCode: 503)])
        let sleeper = TestSleeper(throwCancellationOnSleep: true)

        await #expect(throws: CancellationError.self) {
            _ = try await self.client(server, clock: sleeper).perform(self.request)
        }
        #expect(server.requestCount == 1)
    }

    @Test func requireSuccessAcceptsTheCodesTheCallerNames() throws {
        // WebDAV answers a PROPFIND with 207, and MKCOL with 405 when the folder is already there
        let multiStatus = HTTPClient.Response(data: Data(), statusCode: 207)
        let alreadyExists = HTTPClient.Response(data: Data(), statusCode: 405)

        try multiStatus.requireSuccess()              // 207 is already a success code
        try alreadyExists.requireSuccess(allowing: [405])
        #expect(throws: HTTPClient.StatusError.self) { try alreadyExists.requireSuccess() }
    }

    @Test func requireSuccessReportsTheStatusAndBody() throws {
        let response = HTTPClient.Response(data: Data("no room left".utf8), statusCode: 507)

        do {
            try response.requireSuccess()
            Issue.record("should have thrown")
        } catch let error as HTTPClient.StatusError {
            #expect(error.statusCode == 507)
            #expect(error.bodyText == "no room left")
        }
    }

    private func sorted(_ values: [TimeInterval]) -> [TimeInterval] { values.sorted() }
}

/// Records how long the client wanted to wait, and never really waits.
final class TestSleeper: HTTPSleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []
    private let throwCancellationOnSleep: Bool

    init(throwCancellationOnSleep: Bool = false) {
        self.throwCancellationOnSleep = throwCancellationOnSleep
    }

    var sleeps: [TimeInterval] { lock.withLock { recorded } }

    func sleep(for seconds: TimeInterval) async throws {
        lock.withLock { recorded.append(seconds) }
        if throwCancellationOnSleep { throw CancellationError() }
    }
}
