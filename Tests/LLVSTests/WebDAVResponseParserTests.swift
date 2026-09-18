import Testing
import Foundation
@testable import LLVSWebDAV

@Suite struct WebDAVResponseParserTests {

    /// A PROPFIND reply listing a folder and one file, with the DAV: namespace bound to the prefix given.
    private func multistatus(prefix: String) -> Data {
        let p = prefix.isEmpty ? "" : prefix + ":"
        let xmlns = prefix.isEmpty ? "xmlns" : "xmlns:" + prefix
        return Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <\(p)multistatus \(xmlns)="DAV:">
          <\(p)response>
            <\(p)href>/remote.php/dav/files/me/versions/</\(p)href>
            <\(p)propstat><\(p)prop><\(p)resourcetype><\(p)collection/></\(p)resourcetype></\(p)prop></\(p)propstat>
          </\(p)response>
          <\(p)response>
            <\(p)href>/remote.php/dav/files/me/versions/ABC%20DEF</\(p)href>
            <\(p)propstat><\(p)prop><\(p)resourcetype/></\(p)prop></\(p)propstat>
          </\(p)response>
        </\(p)multistatus>
        """.utf8)
    }

    // Servers choose their own prefix for the DAV: namespace. "D" is common, but not required.
    @Test(arguments: ["D", "d", "", "a", "ns0", "lp1"])
    func itemsAreParsedWhateverTheNamespacePrefix(prefix: String) throws {
        let parser = WebDAVResponseParser(data: multistatus(prefix: prefix))
        try parser.parse()

        #expect(parser.parsedItems.map { $0.name } == ["versions", "ABC DEF"])
        #expect(parser.parsedItems.map { $0.isDirectory } == [true, false])
    }

    @Test func propertiesTheServerCouldNotFindDoNotClearTheName() throws {
        // sabre/dav (Nextcloud) and Apache echo unknown properties in a second propstat, with status 404
        let data = Data("""
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/dav/versions/ABCDEF</d:href>
            <d:propstat><d:prop><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
            <d:propstat><d:prop><d:href/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>
          </d:response>
        </d:multistatus>
        """.utf8)
        let parser = WebDAVResponseParser(data: data)
        try parser.parse()

        #expect(parser.parsedItems.map { $0.name } == ["ABCDEF"])
    }

    @Test func encodedSlashInANameIsNotAPathSeparator() throws {
        let data = Data("""
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/versions/a%2Fb+c</d:href></d:response></d:multistatus>
        """.utf8)
        let parser = WebDAVResponseParser(data: data)
        try parser.parse()

        #expect(parser.parsedItems.map { $0.name } == ["a/b+c"])
    }

    @Test func malformedXMLThrows() {
        let parser = WebDAVResponseParser(data: Data("<D:multistatus".utf8))
        #expect(throws: (any Error).self) { try parser.parse() }
    }
}
