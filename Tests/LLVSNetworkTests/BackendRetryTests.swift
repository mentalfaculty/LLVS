import Testing
import Foundation
@testable import LLVS
@testable import LLVSOneDrive
@testable import LLVSGoogleDrive
@testable import LLVSWebDAV

/// The four file systems now send their requests through `HTTPClient`, so a busy server is waited
/// out rather than reported as a sync failure. These check that at each backend's own call sites.
@Suite struct BackendRetryTests {

    private let webDAVBase = URL(string: "https://example.com/dav")!

    // MARK: - WebDAV

    @Test func webDAVRetriesABusyServerAndThenSucceeds() async throws {
        let server = FakeHTTPServer()
        server.setReplies([
            .init(statusCode: 503),
            .init(statusCode: 200, body: Data("file contents".utf8)),
        ], repeatingLastReply: false)

        let fileSystem = WebDAVFileSystem(baseURL: webDAVBase, session: server.makeSession(), sleeper: TestSleeper())
        let data = try await fileSystem.download(from: "versions/ABC")

        #expect(String(data: data, encoding: .utf8) == "file contents")
        #expect(server.requestCount == 2)
    }

    @Test func webDAVDoesNotRetryAMissingFile() async throws {
        // A 404 means the file is not there, and asking four times will not change that
        let server = FakeHTTPServer()
        server.setReplies([.init(statusCode: 404)])

        let fileSystem = WebDAVFileSystem(baseURL: webDAVBase, session: server.makeSession(), sleeper: TestSleeper())

        await #expect(throws: CloudFileSystemError.self) {
            _ = try await fileSystem.download(from: "versions/ABC")
        }
        #expect(server.requestCount == 1)
    }

    @Test func webDAVStillTreatsMultiStatusAsSuccess() async throws {
        // PROPFIND answers 207, which is not in the 2xx range the generic check allows
        let multiStatus = """
        <?xml version="1.0"?><D:multistatus xmlns:D="DAV:">\
        <D:response><D:href>/dav/versions/</D:href><D:propstat><D:prop>\
        <D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>\
        </D:multistatus>
        """
        let server = FakeHTTPServer()
        server.setReplies([.init(statusCode: 207, body: Data(multiStatus.utf8))])

        let fileSystem = WebDAVFileSystem(baseURL: webDAVBase, session: server.makeSession(), sleeper: TestSleeper())
        let exists = try await fileSystem.fileExists(at: "versions")

        #expect(exists)
    }

    @Test func webDAVTreatsAnExistingDirectoryAsFine() async throws {
        // Creating intermediate directories answers 405 when one is already there, which is not an
        // error. A retry that followed a lost MKCOL reply would see exactly that too.
        let server = FakeHTTPServer()
        server.setReplies([
            .init(statusCode: 404),  // the directory is not there
            .init(statusCode: 405),  // MKCOL says it is, in fact, already there
            .init(statusCode: 201),  // the PUT succeeds
        ], repeatingLastReply: false)

        let fileSystem = WebDAVFileSystem(baseURL: webDAVBase, session: server.makeSession(), sleeper: TestSleeper())

        try await fileSystem.upload(data: Data("x".utf8), to: "versions/ABC")

        #expect(server.requestCount == 3)
    }

    @Test func webDAVWaitsTheTimeAServerAsksFor() async throws {
        let sleeper = TestSleeper()
        let server = FakeHTTPServer()
        server.setReplies([
            .init(statusCode: 429, headers: ["Retry-After": "3"]),
            .init(statusCode: 200, body: Data()),
        ], repeatingLastReply: false)

        let fileSystem = WebDAVFileSystem(baseURL: webDAVBase, session: server.makeSession(), sleeper: sleeper)
        _ = try await fileSystem.download(from: "versions/ABC")

        #expect(sleeper.sleeps == [3.0])
    }

    // MARK: - OneDrive

    @Test func oneDriveRetriesABusyServerAndThenSucceeds() async throws {
        let server = FakeHTTPServer()
        server.setReplies([
            .init(statusCode: 500),
            .init(statusCode: 200, body: Data("payload".utf8)),
        ], repeatingLastReply: false)

        let fileSystem = OneDriveFileSystem(accessToken: "token", session: server.makeSession(), sleeper: TestSleeper())
        let data = try await fileSystem.download(from: "versions/ABC")

        #expect(String(data: data, encoding: .utf8) == "payload")
        #expect(server.requestCount == 2)
    }

    @Test func oneDriveSendsTheTokenOnEveryAttempt() async throws {
        let server = FakeHTTPServer()
        server.setReplies([.init(statusCode: 503), .init(statusCode: 200)], repeatingLastReply: false)

        let fileSystem = OneDriveFileSystem(accessToken: "secret-token", session: server.makeSession(), sleeper: TestSleeper())
        _ = try await fileSystem.download(from: "versions/ABC")

        #expect(server.requests.count == 2)
        for request in server.requests {
            #expect(request.headers["Authorization"] == "Bearer secret-token")
        }
    }

    @Test func oneDriveDoesNotRetryAStaticTokenThatIsRefused() async throws {
        // A static token cannot be refreshed, so a 401 is final rather than worth another attempt
        let server = FakeHTTPServer()
        server.setReplies([.init(statusCode: 401)])

        let fileSystem = OneDriveFileSystem(accessToken: "token", session: server.makeSession(), sleeper: TestSleeper())

        await #expect(throws: CloudFileSystemError.self) {
            _ = try await fileSystem.download(from: "versions/ABC")
        }
        #expect(server.requestCount == 1)
    }

    // MARK: - Google Drive

    @Test func googleDriveRetriesABusyServerAndThenSucceeds() async throws {
        let server = FakeHTTPServer()
        server.setReplies([
            .init(statusCode: 503),
            .init(statusCode: 200, body: Data(#"{"files":[]}"#.utf8)),
        ], repeatingLastReply: false)

        let fileSystem = GoogleDriveFileSystem(accessToken: "token", session: server.makeSession(), sleeper: TestSleeper())
        let names = try await fileSystem.contentsOfDirectory(at: "/")

        #expect(names.isEmpty)
        #expect(server.requestCount == 2)
    }

    @Test func googleDriveSendsAnUploadOnlyOnce() async throws {
        // The upload deletes and re-creates, giving the file a new ID. Repeating it after a lost
        // reply would leave two files at the one path, so it must never be retried.
        //
        // The path lookups have to succeed first, or the upload is never reached. A folder query
        // answering with one match lets `versions` resolve, then the upload itself gets the 503.
        let folderFound = Data(#"{"files":[{"id":"folder-1","name":"versions"}]}"#.utf8)
        let server = FakeHTTPServer()
        server.setReplies([
            .init(statusCode: 200, body: folderFound),  // resolve the "versions" folder
            .init(statusCode: 200, body: folderFound),  // look for an existing file to replace
            .init(statusCode: 204),                     // delete that existing file
            .init(statusCode: 503),                     // the upload: busy, and must not repeat
        ], repeatingLastReply: true)

        let fileSystem = GoogleDriveFileSystem(accessToken: "token", session: server.makeSession(), sleeper: TestSleeper())

        await #expect(throws: (any Error).self) {
            try await fileSystem.upload(data: Data("x".utf8), to: "versions/ABC")
        }

        let uploads = server.requests.filter { $0.url.absoluteString.contains("/upload/drive/") }
        #expect(uploads.count == 1, "requests were: \(server.requests.map { "\($0.method) \($0.url.path)" })")
    }
}
