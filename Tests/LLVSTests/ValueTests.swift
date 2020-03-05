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
        store = try! Store(rootDirectoryURL: rootURL)
        
        originalValue = Value(id: .init("ABCDEF"), data: "Bob".data(using: .utf8)!)
        let changes: [Value.Change] = [.insert(originalValue!)]
        version = try! store.makeVersion(basedOn: nil, storing: changes)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: rootURL)
        super.tearDown()
    }
    
    func testSavingValueCreatesSubDirectoriesAndFile() {
        let v = version.id.rawValue
        let map = v.index(v.startIndex, offsetBy: 1)
        let versionSubDir = String(v[..<map])
        let versionFile = String(v[map...])
        XCTAssert(fm.fileExists(atPath: valuesURL.appendingPathComponent("AB").path))
        XCTAssert(fm.fileExists(atPath: valuesURL.appendingPathComponent("AB/CDEF").path))
        XCTAssert(fm.fileExists(atPath: valuesURL.appendingPathComponent("AB/CDEF/\(versionSubDir)").path))
        XCTAssert(fm.fileExists(atPath: valuesURL.appendingPathComponent("AB/CDEF/\(versionSubDir)/\(versionFile).json").path))
    }
    
    func testSavedFileContainsValue() {
        let v = version.id.rawValue
        let map = v.index(v.startIndex, offsetBy: 1)
        let versionSubDir = String(v[..<map])
        let versionFile = String(v[map...])
        let file = valuesURL.appendingPathComponent("AB/CDEF/\(versionSubDir)/\(versionFile).json")
        let data = try! Data(contentsOf: file)
        XCTAssertEqual(data, "Bob".data(using: .utf8)!)
    }
    
    func testFetchingNonExistentVersionOfValueGivesNil() {
        let version = Version(id: .init(UUID().uuidString), predecessors: nil, valueDataSize: 0)
        let fetchedValue = try! store.value(id: originalValue.id, storedAt: version.id)
        XCTAssertNil(fetchedValue)
    }
    
    func testFetchingSavedVersionOfValue() {
        let value = try! store.value(id: originalValue.id, storedAt: version.id)
        XCTAssertNotNil(value)
        XCTAssertEqual(value!.id.rawValue, originalValue.id.rawValue)
        XCTAssertEqual(value!.storedVersionId!, version.id)
        XCTAssertEqual(value!.data, "Bob".data(using: .utf8)!)
    }
    
    func testAllVersionsOfValue() {
        let newValue = Value(id: .init("ABCDEF"), data: "Dave".data(using: .utf8)!)
        let changes: [Value.Change] = [.insert(newValue)]
        let newVersion = try! store.makeVersion(basedOn: nil, storing: changes)
        
        let versionIds = try! store.versionIds(for: newValue.id)
        
        XCTAssertEqual(versionIds.count, 2)
        
        let versions: Set<Version.ID> = [version!.id, newVersion.id]
        let fetchedVersions = Set(versionIds)
        XCTAssertEqual(versions, fetchedVersions)
    }
    
    static var allTests = [
        ("testSavingValueCreatesSubDirectoriesAndFile", testSavingValueCreatesSubDirectoriesAndFile),
        ("testSavedFileContainsValue", testSavedFileContainsValue),
        ("testFetchingNonExistentVersionOfValueGivesNil", testFetchingNonExistentVersionOfValueGivesNil),
        ("testFetchingSavedVersionOfValue", testFetchingSavedVersionOfValue),
        ("testAllVersionsOfValue", testAllVersionsOfValue),
        ]
}
