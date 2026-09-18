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

    @Test func cancellationStopsTheRetries() async throws {
        let server = FakeHTTPServer()
        server.setReplies([.init(statusCode: 503)])
        let sleeper = TestSleeper(throwCancellationOnSleep: true)

        await #expect(throws: CancellationError.self) {
            _ = try await self.client(server, clock: sleeper).perform(self.request)
        }
        #expect(server.requestCount == 1)
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
