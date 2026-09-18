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

    @Test func storageThatCannotMakeZonesFailsAtInit() throws {
        // The zones were made lazily with try!, so this used to crash at the first read or write
        struct ZoneFailure: Swift.Error {}
        struct FailingStorage: Storage {
            func makeValuesZone(in store: Store) throws -> Zone { throw ZoneFailure() }
            func makeMapZone(for type: MapType, in store: Store) throws -> Zone { throw ZoneFailure() }
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ZoneFailure.self) { try Store(rootDirectoryURL: url, storage: FailingStorage()) }
    }
}
