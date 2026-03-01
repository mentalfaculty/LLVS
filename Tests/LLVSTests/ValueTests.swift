import Testing
import Foundation
@testable import LLVS

@Suite class ValueTests {

    let fm = FileManager.default

    let store: Store
    let rootURL: URL
    let valuesURL: URL
    let version: Version
    let originalValue: Value

    init() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        valuesURL = rootURL.appendingPathComponent("values")
        store = try Store(rootDirectoryURL: rootURL)

        originalValue = Value(id: .init("ABCDEF"), data: "Bob".data(using: .utf8)!)
        let changes: [Value.Change] = [.insert(originalValue)]
        version = try store.makeVersion(basedOn: nil, storing: changes)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    @Test func savingValueCreatesSubDirectoriesAndFile() {
        let v = version.id.rawValue
        let map = v.index(v.startIndex, offsetBy: 1)
        let versionSubDir = String(v[..<map])
        let versionFile = String(v[map...])
        #expect(fm.fileExists(atPath: valuesURL.appendingPathComponent("AB").path))
        #expect(fm.fileExists(atPath: valuesURL.appendingPathComponent("AB/CDEF").path))
        #expect(fm.fileExists(atPath: valuesURL.appendingPathComponent("AB/CDEF/\(versionSubDir)").path))
        #expect(fm.fileExists(atPath: valuesURL.appendingPathComponent("AB/CDEF/\(versionSubDir)/\(versionFile).json").path))
    }

    @Test func savedFileContainsValue() throws {
        let v = version.id.rawValue
        let map = v.index(v.startIndex, offsetBy: 1)
        let versionSubDir = String(v[..<map])
        let versionFile = String(v[map...])
        let file = valuesURL.appendingPathComponent("AB/CDEF/\(versionSubDir)/\(versionFile).json")
        let data = try Data(contentsOf: file)
        #expect(data == "Bob".data(using: .utf8)!)
    }

    @Test func fetchingNonExistentVersionOfValueGivesNil() throws {
        let version = Version(id: .init(UUID().uuidString), predecessors: nil, valueDataSize: 0)
        let fetchedValue = try store.value(id: originalValue.id, storedAt: version.id)
        #expect(fetchedValue == nil)
    }

    @Test func fetchingSavedVersionOfValue() throws {
        let value = try store.value(id: originalValue.id, storedAt: version.id)
        #expect(value != nil)
        #expect(value!.id.rawValue == originalValue.id.rawValue)
        #expect(value!.storedVersionId! == version.id)
        #expect(value!.data == "Bob".data(using: .utf8)!)
    }

    @Test func allVersionsOfValue() throws {
        let newValue = Value(id: .init("ABCDEF"), data: "Dave".data(using: .utf8)!)
        let changes: [Value.Change] = [.insert(newValue)]
        let newVersion = try store.makeVersion(basedOn: nil, storing: changes)

        let versionIds = try store.versionIds(for: newValue.id)

        #expect(versionIds.count == 2)

        let versions: Set<Version.ID> = [version.id, newVersion.id]
        let fetchedVersions = Set(versionIds)
        #expect(versions == fetchedVersions)
    }
}
