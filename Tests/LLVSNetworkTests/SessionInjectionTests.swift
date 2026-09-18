import Testing
import Foundation
@testable import LLVSOneDrive
@testable import LLVSGoogleDrive
@testable import LLVSWebDAV

@Suite struct SessionInjectionTests {

    @Test func oneDriveUsesTheSessionItIsGiven() async throws {
        let server = FakeHTTPServer()
        server.setReplies([.init(statusCode: 404)])
        let fileSystem = OneDriveFileSystem(accessToken: "token", session: server.makeSession())

        let exists = try await fileSystem.fileExists(at: "versions/ABC")

        #expect(exists == false)
        #expect(server.requestCount == 1)
    }

    @Test func googleDriveUsesTheSessionItIsGiven() async throws {
        let server = FakeHTTPServer()
        server.setReplies([.init(statusCode: 200, body: Data(#"{"files":[]}"#.utf8))])
        let fileSystem = GoogleDriveFileSystem(accessToken: "token", session: server.makeSession())

        _ = try? await fileSystem.contentsOfDirectory(at: "versions")

        #expect(server.requestCount >= 1)
    }

    @Test func webDAVUsesTheSessionItIsGiven() async throws {
        let server = FakeHTTPServer()
        server.setReplies([.init(statusCode: 404)])
        let fileSystem = WebDAVFileSystem(baseURL: URL(string: "https://example.com/dav")!, session: server.makeSession())

        let exists = try await fileSystem.fileExists(at: "versions/ABC")

        #expect(exists == false)
        #expect(server.requestCount == 1)
    }
}
