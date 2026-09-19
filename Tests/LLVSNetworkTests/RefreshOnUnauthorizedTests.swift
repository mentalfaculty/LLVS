import Testing
import Foundation
@testable import LLVS
@testable import LLVSOneDrive
@testable import LLVSGoogleDrive

/// Before this, a revoked access token stopped sync dead: the 401 came back to the app as a failure
/// even though the refresh token was still good. Now one 401 costs one refresh and one repeat.
@Suite struct RefreshOnUnauthorizedTests {

    /// Keeps the credential in memory, so no test needs an unlocked Keychain.
    private final class MemoryStorage: OAuthCredentialStorage, @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?

        func load() -> Data? { lock.withLock { data } }
        func save(_ newData: Data) { lock.withLock { data = newData } }
        func delete() { lock.withLock { data = nil } }
    }

    private let refreshedTokenBody = Data(#"{"access_token":"fresh-token","expires_in":3600}"#.utf8)

    private func makeOneDriveAuthenticator(session: URLSession) async -> OneDriveAuthenticator {
        let authenticator = OneDriveAuthenticator(
            configuration: .init(clientID: "client", redirectURI: "msauth.test://auth"),
            storage: MemoryStorage(),
            session: session,
            sleeper: TestSleeper()
        )
        // A token that still looks valid, so the 401 is what triggers the refresh, not the clock
        await authenticator.seed(
            accessToken: "stale-token",
            refreshToken: "refresh-token",
            expiresAt: Date().addingTimeInterval(3600)
        )
        return authenticator
    }

    @Test func aRefusedTokenIsRefreshedAndTheRequestRepeated() async throws {
        let server = FakeHTTPServer()
        server.setReplies([
            .init(statusCode: 401),                               // the stale token is refused
            .init(statusCode: 200, body: refreshedTokenBody),     // the refresh succeeds
            .init(statusCode: 200, body: Data("payload".utf8)),   // the repeat works
        ], repeatingLastReply: false)

        let session = server.makeSession()
        let authenticator = await makeOneDriveAuthenticator(session: session)
        let fileSystem = OneDriveFileSystem(authenticator: authenticator, session: session, sleeper: TestSleeper())

        let data = try await fileSystem.download(from: "versions/ABC")

        #expect(String(data: data, encoding: .utf8) == "payload")
        #expect(server.requestCount == 3)

        // The repeat must carry the new token, not the one the server just refused
        let lastRequest = try #require(server.requests.last)
        #expect(lastRequest.headers["Authorization"] == "Bearer fresh-token")
    }

    @Test func theRefreshRequestCarriesTheRefreshToken() async throws {
        let server = FakeHTTPServer()
        server.setReplies([
            .init(statusCode: 401),
            .init(statusCode: 200, body: refreshedTokenBody),
            .init(statusCode: 200, body: Data("payload".utf8)),
        ], repeatingLastReply: false)

        let session = server.makeSession()
        let authenticator = await makeOneDriveAuthenticator(session: session)
        let fileSystem = OneDriveFileSystem(authenticator: authenticator, session: session, sleeper: TestSleeper())

        _ = try await fileSystem.download(from: "versions/ABC")

        let refreshRequest = server.requests[1]
        let body = String(data: refreshRequest.body ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("refresh_token=refresh-token"))
    }

    @Test func aSecondRefusalIsReportedRatherThanLoopingForever() async throws {
        // If the fresh token is refused too, something is really wrong. One refresh, then give up.
        let server = FakeHTTPServer()
        server.setReplies([
            .init(statusCode: 401),                            // the stale token is refused
            .init(statusCode: 200, body: refreshedTokenBody),  // the refresh succeeds
            .init(statusCode: 401),                            // and the new token is refused too
        ], repeatingLastReply: true)

        let session = server.makeSession()
        let authenticator = await makeOneDriveAuthenticator(session: session)
        let fileSystem = OneDriveFileSystem(authenticator: authenticator, session: session, sleeper: TestSleeper())

        await #expect(throws: CloudFileSystemError.self) {
            _ = try await fileSystem.download(from: "versions/ABC")
        }
        #expect(server.requestCount == 3, "one refresh and one repeat, then stop")
    }

    @Test func aTokenExpiringMidListingCostsOnlyThatPage() async throws {
        // Each page takes a fresh token, so the refresh sits below the pagination loop. A 401 on
        // page two repeats page two, not the whole listing.
        let firstPage = Data(#"{"value":[{"name":"one"}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/next"}"#.utf8)
        let secondPage = Data(#"{"value":[{"name":"two"}]}"#.utf8)

        let server = FakeHTTPServer()
        server.setReplies([
            .init(statusCode: 200, body: firstPage),           // page one is fine
            .init(statusCode: 401),                            // page two: the token has died
            .init(statusCode: 200, body: refreshedTokenBody),  // refresh
            .init(statusCode: 200, body: secondPage),          // page two again, and it works
        ], repeatingLastReply: false)

        let session = server.makeSession()
        let authenticator = await makeOneDriveAuthenticator(session: session)
        let fileSystem = OneDriveFileSystem(authenticator: authenticator, session: session, sleeper: TestSleeper())

        let names = try await fileSystem.contentsOfDirectory(at: "versions")

        #expect(names == ["one", "two"], "both pages are returned, and page one is not fetched twice")
        #expect(server.requestCount == 4)
    }

    @Test func googleDriveAlsoRefreshesOnARefusedToken() async throws {
        let server = FakeHTTPServer()
        server.setReplies([
            .init(statusCode: 401),
            .init(statusCode: 200, body: refreshedTokenBody),
            .init(statusCode: 200, body: Data(#"{"files":[]}"#.utf8)),
        ], repeatingLastReply: false)

        let session = server.makeSession()
        let authenticator = GoogleDriveAuthenticator(
            configuration: .init(clientID: "client", redirectURI: "com.test:/oauth2callback"),
            storage: MemoryStorage(),
            session: session,
            sleeper: TestSleeper()
        )
        await authenticator.seed(
            accessToken: "stale-token",
            refreshToken: "refresh-token",
            expiresAt: Date().addingTimeInterval(3600)
        )
        let fileSystem = GoogleDriveFileSystem(authenticator: authenticator, session: session, sleeper: TestSleeper())

        let names = try await fileSystem.contentsOfDirectory(at: "/")

        #expect(names.isEmpty)
        #expect(server.requestCount == 3)
        let lastRequest = try #require(server.requests.last)
        #expect(lastRequest.headers["Authorization"] == "Bearer fresh-token")
    }

    @Test func anUploadStaysUnrepeatableAfterARefresh() async throws {
        // The retry after a refresh must carry `isSafeToRepeat: false` as well as the first attempt.
        // If it did not, a token expiring just before an upload would turn one upload into four,
        // and Google Drive would end up with four copies at the one path.
        let folderFound = Data(#"{"files":[{"id":"folder-1","name":"versions"}]}"#.utf8)
        let server = FakeHTTPServer()
        server.setReplies([
            .init(statusCode: 200, body: folderFound),         // resolve the folder
            .init(statusCode: 200, body: folderFound),         // find the file to replace
            .init(statusCode: 204),                            // delete it
            .init(statusCode: 401),                            // the upload: the token has died
            .init(statusCode: 200, body: refreshedTokenBody),  // refresh
            .init(statusCode: 503),                            // the upload again: busy
        ], repeatingLastReply: true)

        let session = server.makeSession()
        let authenticator = GoogleDriveAuthenticator(
            configuration: .init(clientID: "client", redirectURI: "com.test:/oauth2callback"),
            storage: MemoryStorage(),
            session: session,
            sleeper: TestSleeper()
        )
        await authenticator.seed(
            accessToken: "stale-token",
            refreshToken: "refresh-token",
            expiresAt: Date().addingTimeInterval(3600)
        )
        let fileSystem = GoogleDriveFileSystem(authenticator: authenticator, session: session, sleeper: TestSleeper())

        await #expect(throws: (any Error).self) {
            try await fileSystem.upload(data: Data("x".utf8), to: "versions/ABC")
        }

        // Two uploads exactly: the one that got the 401, and the one retry after the refresh.
        // The 503 must not start the backoff loop
        let uploads = server.requests.filter { $0.url.absoluteString.contains("/upload/drive/") }
        #expect(uploads.count == 2, "requests were: \(server.requests.map { "\($0.method) \($0.url.path)" })")
    }

    @Test func concurrentDownloadsRefusedTogetherShareOneRefresh() async throws {
        // Several transfers run at once and all get a 401 from the same dead token. They should
        // cause one refresh between them, and all go on to succeed with the new token.
        let server = FakeHTTPServer()
        // The fake answers by order of arrival, so a 401 for each of the four, then the refresh,
        // then the repeats. `repeatingLastReply` covers however the last few interleave
        server.setReplies([
            .init(statusCode: 401),
            .init(statusCode: 401),
            .init(statusCode: 401),
            .init(statusCode: 401),
            .init(statusCode: 200, body: refreshedTokenBody),
            .init(statusCode: 200, body: Data("payload".utf8)),
        ], repeatingLastReply: true)

        let session = server.makeSession()
        let authenticator = await makeOneDriveAuthenticator(session: session)
        let fileSystem = OneDriveFileSystem(authenticator: authenticator, session: session, sleeper: TestSleeper())

        let payloads = try await withThrowingTaskGroup(of: Data.self) { group in
            for index in 0..<4 {
                group.addTask { try await fileSystem.download(from: "versions/ABC-\(index)") }
            }
            var collected: [Data] = []
            for try await payload in group { collected.append(payload) }
            return collected
        }

        #expect(payloads.count == 4)
        #expect(payloads.allSatisfy { String(data: $0, encoding: .utf8) == "payload" })

        // Exactly one refresh: four of these would mean the single-flight collapse did nothing
        let refreshes = server.requests.filter { $0.url.absoluteString.contains("/oauth2/v2.0/token") }
        #expect(refreshes.count == 1, "four concurrent 401s should cause one refresh, not four")

        // And every repeat used the new token
        let authorized = server.requests.filter { $0.headers["Authorization"] != nil }
        #expect(authorized.suffix(4).allSatisfy { $0.headers["Authorization"] == "Bearer fresh-token" })
    }

    @Test func aStaticTokenIsNotRefreshed() async throws {
        // There is nothing to refresh with, so the 401 goes straight back to the caller
        let server = FakeHTTPServer()
        server.setReplies([.init(statusCode: 401)])

        let fileSystem = OneDriveFileSystem(accessToken: "static-token", session: server.makeSession(), sleeper: TestSleeper())

        await #expect(throws: CloudFileSystemError.self) {
            _ = try await fileSystem.download(from: "versions/ABC")
        }
        #expect(server.requestCount == 1)
    }
}
