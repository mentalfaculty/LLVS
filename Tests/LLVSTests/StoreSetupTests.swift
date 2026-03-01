import Testing
import Foundation
@testable import LLVS

@Suite class StoreSetupTests {

    let store: Store
    let rootURL: URL

    init() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store = try Store(rootDirectoryURL: rootURL)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    @Test func storeCreatesDirectories() {
        let fm = FileManager.default
        let root = rootURL.path as NSString
        #expect(fm.fileExists(atPath: root as String))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("versions")))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("values")))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("maps")))
    }
}
