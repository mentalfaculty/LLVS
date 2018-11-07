import XCTest
import Foundation
@testable import LLVS

final class ValueTests: XCTestCase {
    
    let fm = FileManager.default

    var store: Store!
    var rootURL: URL!
    var valuesURL: URL!
    var version: Version!
    var originalValue: Value!
    
    override func setUp() {
        super.setUp()
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        valuesURL = rootURL.appendingPathComponent("values")
        store = Store(rootDirectoryURL: rootURL)
        
        originalValue = Value(identifier: .init(identifierString: "ABCDEF"), version: nil, properties: ["name":"Bob"])
        var values = [originalValue!]
        version = try! store.addVersion(basedOn: nil, saving: &values)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: rootURL)
        super.tearDown()
    }
    
    func testSavingValueCreatesSubDirectoriesAndFile() {
        let v = version.identifier.identifierString
        let index = v.index(v.startIndex, offsetBy: 1)
        let versionSubDir = String(v[..<index])
        let versionFile = String(v[index...])
        XCTAssert(fm.fileExists(atPath: valuesURL.appendingPathComponent("AB").path))
        XCTAssert(fm.fileExists(atPath: valuesURL.appendingPathComponent("AB/CDEF").path))
        XCTAssert(fm.fileExists(atPath: valuesURL.appendingPathComponent("AB/CDEF/\(versionSubDir)").path))
        XCTAssert(fm.fileExists(atPath: valuesURL.appendingPathComponent("AB/CDEF/\(versionSubDir)/\(versionFile).json").path))
    }
    
    func testSavedFileContainsValue() {
        let v = version.identifier.identifierString
        let index = v.index(v.startIndex, offsetBy: 1)
        let versionSubDir = String(v[..<index])
        let versionFile = String(v[index...])
        let file = valuesURL.appendingPathComponent("AB/CDEF/\(versionSubDir)/\(versionFile).json")
        let decoder = JSONDecoder()
        let value = try! decoder.decode(Value.self, from: Data(contentsOf: file))
        XCTAssertEqual(value.identifier.identifierString, originalValue.identifier.identifierString)
        XCTAssertEqual(value.version!, version!)
        XCTAssertEqual(value.properties["name"]!, "Bob")
    }
    
    static var allTests = [
        ("testSavingValueCreatesSubDirectoriesAndFile", testSavingValueCreatesSubDirectoriesAndFile),
        ]
}
