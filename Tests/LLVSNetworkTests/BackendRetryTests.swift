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

    // MARK: - Google Drive Duplicate Folders

    /// Two folders of the same name, as Drive reports them. Drive permits duplicates, and the
    /// order it returns them in is not guaranteed.
    private func duplicateFolders(_ ids: [String], name: String) -> Data {
        let entries = ids.map { #"{"id":"\#($0)","name":"\#(name)"}"# }.joined(separator: ",")
        return Data(#"{"files":[\#(entries)]}"#.utf8)
    }

    @Test func googleDrivePicksTheSameDuplicateFolderWhateverTheOrder() async throws {
        // Two devices racing on first sync each create a folder named "versions". Every device has
        // to settle on the same one, or they write into different folders and never converge.
        // Drive does not promise an order, so the choice cannot depend on it.
        let firstOrder = FakeHTTPServer()
        firstOrder.setReplies([.init(statusCode: 200, body: duplicateFolders(["id-b", "id-a"], name: "versions"))])
        let firstSystem = GoogleDriveFileSystem(accessToken: "token", session: firstOrder.makeSession(), sleeper: TestSleeper())

        let secondOrder = FakeHTTPServer()
        secondOrder.setReplies([.init(statusCode: 200, body: duplicateFolders(["id-a", "id-b"], name: "versions"))])
        let secondSystem = GoogleDriveFileSystem(accessToken: "token", session: secondOrder.makeSession(), sleeper: TestSleeper())

        _ = try await firstSystem.contentsOfDirectory(at: "versions")
        _ = try await secondSystem.contentsOfDirectory(at: "versions")

        // Each listed the children of whichever folder it settled on, so the parent in the query
        // says which one that was. Both must have chosen the same
        let firstParent = try #require(parentIDInLastQuery(firstOrder))
        let secondParent = try #require(parentIDInLastQuery(secondOrder))
        #expect(firstParent == secondParent, "the two devices chose different folders")
        #expect(firstParent == "id-a", "the agreed winner should be the lowest id")
    }

    @Test func googleDriveResolvesTheSameFolderItJustCreated() async throws {
        // After creating a folder, the code asks again and takes the agreed winner. If another
        // device won the race, that is the other device's folder, not the one just created.
        // The id this device creates must NOT be the winning one, or the test passes whether or
        // not the re-query happens. "zzz-mine" loses to "aaa-theirs" on the lowest-id tiebreak.
        let server = FakeHTTPServer()
        server.setReplies([
            .init(statusCode: 200, body: Data(#"{"files":[]}"#.utf8)),                                   // nothing there yet
            .init(statusCode: 200, body: Data(#"{"id":"zzz-mine"}"#.utf8)),                              // this device creates one
            .init(statusCode: 200, body: duplicateFolders(["zzz-mine", "aaa-theirs"], name: "versions")),// the other device won the race
            .init(statusCode: 200, body: Data(#"{"files":[]}"#.utf8)),                                   // no existing file to replace
            .init(statusCode: 200, body: Data(#"{"id":"file-1"}"#.utf8)),                                // the upload
        ], repeatingLastReply: true)

        let fileSystem = GoogleDriveFileSystem(accessToken: "token", session: server.makeSession(), sleeper: TestSleeper())
        try await fileSystem.upload(data: Data("x".utf8), to: "versions/ABC")

        // The upload must go into the agreed folder — the other device's — not the one made here
        let uploads = server.requests.filter { $0.url.absoluteString.contains("/upload/drive/") }
        let body = try #require(uploads.first?.body)
        let bodyText = String(data: body, encoding: .utf8) ?? ""
        #expect(bodyText.contains("aaa-theirs"), "expected the agreed folder id in: \(bodyText)")
        #expect(!bodyText.contains("zzz-mine"), "it used the folder it created instead of the agreed one")
    }

    @Test func googleDriveSeesDuplicatesSpreadAcrossPages() async throws {
        // Drive pages at 100 by default and promises no order, so the lowest id of one page is not
        // the lowest id. The winner would then depend on which page a device happened to get,
        // which is the disagreement the tiebreak exists to prevent. The lookup must page.
        let firstPage = Data(#"{"files":[{"id":"m-second","name":"versions"}],"nextPageToken":"page-2"}"#.utf8)
        let secondPage = Data(#"{"files":[{"id":"a-first","name":"versions"}]}"#.utf8)

        let server = FakeHTTPServer()
        server.setReplies([
            .init(statusCode: 200, body: firstPage),
            .init(statusCode: 200, body: secondPage),
        ], repeatingLastReply: true)

        let fileSystem = GoogleDriveFileSystem(accessToken: "token", session: server.makeSession(), sleeper: TestSleeper())
        _ = try await fileSystem.contentsOfDirectory(at: "versions")

        // The winner must be the lowest across BOTH pages, not the only one on the first
        let parent = try #require(parentIDInLastQuery(server))
        #expect(parent == "a-first", "the second page was never fetched, so the wrong folder won")
    }

    @Test func googleDriveAsksDriveToReturnThePageToken() async throws {
        // Drive omits any field not named in `fields`, so without asking for nextPageToken a
        // truncated result is indistinguishable from a complete one — it would page zero times
        // and look correct
        let server = FakeHTTPServer()
        server.setReplies([.init(statusCode: 200, body: duplicateFolders(["id-a"], name: "versions"))])
        let fileSystem = GoogleDriveFileSystem(accessToken: "token", session: server.makeSession(), sleeper: TestSleeper())

        _ = try await fileSystem.contentsOfDirectory(at: "versions")

        let lookup = try #require(server.requests.first)
        let fields = URLComponents(url: lookup.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "fields" }?.value ?? ""
        #expect(fields.contains("nextPageToken"), "fields was: \(fields)")
    }

    @Test func googleDriveDoesNotDeleteTheDuplicateFolder() async throws {
        // The loser may already hold another device's versions. Deleting it would destroy them,
        // so the extra folder is left alone.
        let server = FakeHTTPServer()
        server.setReplies([.init(statusCode: 200, body: duplicateFolders(["id-a", "id-b"], name: "versions"))])
        let fileSystem = GoogleDriveFileSystem(accessToken: "token", session: server.makeSession(), sleeper: TestSleeper())

        _ = try await fileSystem.contentsOfDirectory(at: "versions")

        #expect(!server.requests.contains { $0.method == "DELETE" }, "a duplicate folder must not be deleted")
    }

    /// The `'<id>' in parents` clause of the last query the server was asked to run.
    private func parentIDInLastQuery(_ server: FakeHTTPServer) -> String? {
        for request in server.requests.reversed() {
            guard let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value else { continue }
            guard let start = query.range(of: "'"), let end = query.range(of: "' in parents") else { continue }
            return String(query[start.upperBound..<end.lowerBound])
        }
        return nil
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
