import XCTest
import Foundation
@testable import LLVS

final class StoreSetupTests: XCTestCase {
    
    var store: Store!
    var rootURL: URL!
    
    override func setUp() {
        super.setUp()
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store = Store(rootDirectoryURL: rootURL)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: rootURL)
        super.tearDown()
    }
    
    func testStoreCreatesDirectories() {
        let fm = FileManager.default
        let root = rootURL.path as NSString
        XCTAssert(fm.fileExists(atPath: root as String))
        XCTAssert(fm.fileExists(atPath: root.appendingPathComponent("versions")))
        XCTAssert(fm.fileExists(atPath: root.appendingPathComponent("values")))
        XCTAssert(fm.fileExists(atPath: root.appendingPathComponent("filters")))
    }

    static var allTests = [
        ("testStoreCreatesDirectories", testStoreCreatesDirectories),
    ]
}
