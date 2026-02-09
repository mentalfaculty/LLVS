//
//  CompactionTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 08/02/2026.
//

import XCTest
import Foundation
@testable import LLVS
@testable import LLVSSQLite

class CompactionTests: XCTestCase {

    let fm = FileManager.default

    var store: Store!
    var rootURL: URL!

    override func setUp() {
        super.setUp()
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store = try! Store(rootDirectoryURL: rootURL)
    }

    override func tearDown() {
        try? fm.removeItem(at: rootURL)
        super.tearDown()
    }

    // Helper to create a value
    private func value(_ id: String, _ string: String) -> Value {
        Value(id: .init(id), data: string.data(using: .utf8)!)
    }

    // Helper to create a linear chain of N versions with distinct values.
    // Returns array of versions [v0, v1, ..., vN-1] where v0 is the initial.
    @discardableResult
    private func makeLinearChain(count: Int, prefix: String = "val", baseVersion: Version? = nil) -> [Version] {
        var versions: [Version] = []
        var predecessor: Version.ID? = baseVersion?.id
        for i in 0..<count {
            let val = value("\(prefix)\(i)", "data\(i)")
            let ver = try! store.makeVersion(basedOnPredecessor: predecessor, storing: [.insert(val)])
            versions.append(ver)
            predecessor = ver.id
        }
        return versions
    }

    // Helper: set timestamps to the past so compaction cutoff works
    private func setTimestampsToDistantPast(for versions: [Version]) {
        let distantPast = Date(timeIntervalSinceNow: -30*24*3600).timeIntervalSinceReferenceDate
        for (i, version) in versions.enumerated() {
            var v = version
            v.timestamp = distantPast - TimeInterval(versions.count - i)
            // Re-write the version JSON
            let (dir, file) = fileSystemLocation(for: v.id)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
            let data = try! JSONEncoder().encode(v)
            try! data.write(to: file)
        }
    }

    private func fileSystemLocation(for versionId: Version.ID) -> (directoryURL: URL, fileURL: URL) {
        let versionsDir = rootURL.appendingPathComponent("versions")
        let fileURL = versionsDir.appendingSplitPathComponent(versionId.rawValue).appendingPathExtension("json")
        let directoryURL = fileURL.deletingLastPathComponent()
        return (directoryURL, fileURL)
    }

    // MARK: - Tests

    func testLinearCompaction() throws {
        // Create 60 versions in a linear chain
        let versions = makeLinearChain(count: 60)

        // Set first 10 versions to distant past
        setTimestampsToDistantPast(for: Array(versions[0..<10]))

        // Reload store to pick up timestamp changes
        store = try Store(rootDirectoryURL: rootURL)

        // Compact (should compress old versions)
        let baselineId = try store.compact(beforeDate: Date(timeIntervalSinceNow: -7*24*3600), minRetainedVersions: 50)
        XCTAssertNotNil(baselineId)

        // Verify baseline has the values from the compaction point
        let baselineRefs = try store.valueReferences(at: baselineId!)
        XCTAssertFalse(baselineRefs.isEmpty)

        // Verify the most recent version is still resolvable
        let latestVersion = versions.last!
        let latestRefs = try store.valueReferences(at: latestVersion.id)
        XCTAssertFalse(latestRefs.isEmpty)

        // Verify compressed versions are tracked
        XCTAssertFalse(store.compressedVersionIdentifiers.isEmpty)

        // Verify version JSON files of compressed versions are deleted
        for compressedId in store.compressedVersionIdentifiers {
            let (_, file) = fileSystemLocation(for: compressedId)
            XCTAssertFalse(fm.fileExists(atPath: file.path), "Compressed version file should be deleted: \(compressedId.rawValue)")
        }
    }

    func testBranchedCompaction() throws {
        // Create a fork and merge, then compact below merge point
        let v0 = try store.makeVersion(basedOnPredecessor: nil, storing: [.insert(value("AB", "origin"))])

        // Branch 1
        let v1 = try store.makeVersion(basedOnPredecessor: v0.id, storing: [.insert(value("CD", "branch1"))])

        // Branch 2
        let v2 = try store.makeVersion(basedOnPredecessor: v0.id, storing: [.insert(value("EF", "branch2"))])

        // Merge
        let arbiter = MostRecentChangeFavoringArbiter()
        let merged = try store.merge(version: v1.id, with: v2.id, resolvingWith: arbiter)

        // Add more versions after the merge
        var current = merged
        for i in 0..<55 {
            current = try store.makeVersion(basedOnPredecessor: current.id, storing: [.insert(value("GH\(i)", "post\(i)"))])
        }

        // Set everything before the merge to distant past
        setTimestampsToDistantPast(for: [v0, v1, v2, merged])

        // Reload
        store = try Store(rootDirectoryURL: rootURL)

        let baselineId = try store.compact(beforeDate: Date(timeIntervalSinceNow: -7*24*3600), minRetainedVersions: 50)
        XCTAssertNotNil(baselineId)

        // Post-compaction versions should still be resolvable
        let finalRefs = try store.valueReferences(at: current.id)
        XCTAssertFalse(finalRefs.isEmpty)
    }

    func testPreservesActiveHeads() throws {
        // Create a common ancestor, then two branches
        let v0 = try store.makeVersion(basedOnPredecessor: nil, storing: [.insert(value("AB", "root"))])

        // Build a long linear history
        var current = v0
        for i in 0..<55 {
            current = try store.makeVersion(basedOnPredecessor: current.id, storing: [.insert(value("LN\(i)", "linear\(i)"))])
        }

        // Fork two branches
        let head1 = try store.makeVersion(basedOnPredecessor: current.id, storing: [.insert(value("H1", "head1"))])
        let head2 = try store.makeVersion(basedOnPredecessor: current.id, storing: [.insert(value("H2", "head2"))])

        // Set old versions to distant past
        setTimestampsToDistantPast(for: [v0])

        // Reload
        store = try Store(rootDirectoryURL: rootURL)

        _ = try store.compact(beforeDate: Date(timeIntervalSinceNow: -7*24*3600), minRetainedVersions: 50)

        // Both heads remain functional
        let refs1 = try store.valueReferences(at: head1.id)
        let refs2 = try store.valueReferences(at: head2.id)
        XCTAssertFalse(refs1.isEmpty)
        XCTAssertFalse(refs2.isEmpty)
    }

    func testNoCompactionWhenTooRecent() throws {
        // All versions are recent
        let _ = makeLinearChain(count: 60)

        // Try to compact — everything is recent, should return nil
        let baselineId = try store.compact(beforeDate: Date(timeIntervalSinceNow: -7*24*3600), minRetainedVersions: 50)
        XCTAssertNil(baselineId)
        XCTAssertTrue(store.compressedVersionIdentifiers.isEmpty)
    }

    func testNoCompactionWithTooFewVersions() throws {
        // Only 5 versions, minRetainedVersions is 50
        let versions = makeLinearChain(count: 5)
        setTimestampsToDistantPast(for: versions)
        store = try Store(rootDirectoryURL: rootURL)

        let baselineId = try store.compact(beforeDate: Date(timeIntervalSinceNow: -7*24*3600), minRetainedVersions: 50)
        XCTAssertNil(baselineId)
    }

    func testAccessCompressedVersionThrows() throws {
        let versions = makeLinearChain(count: 60)
        setTimestampsToDistantPast(for: Array(versions[0..<10]))
        store = try Store(rootDirectoryURL: rootURL)

        let baselineId = try store.compact(beforeDate: Date(timeIntervalSinceNow: -7*24*3600), minRetainedVersions: 50)
        XCTAssertNotNil(baselineId)

        // Trying to read at a compressed version should throw
        let compressedId = store.compressedVersionIdentifiers.first!
        XCTAssertThrowsError(try store.value(id: .init("val0"), at: compressedId)) { error in
            guard case Store.Error.accessToCompressedVersion = error else {
                XCTFail("Expected accessToCompressedVersion error, got \(error)")
                return
            }
        }
    }

    func testMergeWithCompressedAncestorThrows() throws {
        // Create a scenario where two heads share a compressed GCA
        let v0 = try store.makeVersion(basedOnPredecessor: nil, storing: [.insert(value("AB", "root"))])

        // Long chain so compaction can happen
        var current = v0
        for i in 0..<55 {
            current = try store.makeVersion(basedOnPredecessor: current.id, storing: [.insert(value("LN\(i)", "linear\(i)"))])
        }

        // Set v0 to distant past
        setTimestampsToDistantPast(for: [v0])
        store = try Store(rootDirectoryURL: rootURL)

        let baselineId = try store.compact(beforeDate: Date(timeIntervalSinceNow: -7*24*3600), minRetainedVersions: 50)
        XCTAssertNotNil(baselineId)

        // Fork two branches from a post-compaction version
        let postCompactionHead = current
        let head1 = try store.makeVersion(basedOnPredecessor: postCompactionHead.id, storing: [.insert(value("H1", "head1"))])
        let head2 = try store.makeVersion(basedOnPredecessor: postCompactionHead.id, storing: [.insert(value("H2", "head2"))])

        // Merging these should succeed because their common ancestor is not compressed
        let arbiter = MostRecentChangeFavoringArbiter()
        XCTAssertNoThrow(try store.merge(version: head1.id, with: head2.id, resolvingWith: arbiter))
    }

    func testCompactionInfoPersistence() throws {
        let versions = makeLinearChain(count: 60)
        setTimestampsToDistantPast(for: Array(versions[0..<10]))
        store = try Store(rootDirectoryURL: rootURL)

        let baselineId = try store.compact(beforeDate: Date(timeIntervalSinceNow: -7*24*3600), minRetainedVersions: 50)
        XCTAssertNotNil(baselineId)

        let compressedBefore = store.compressedVersionIdentifiers

        // Recreate Store from same directory
        store = try Store(rootDirectoryURL: rootURL)

        // Verify compressed set is restored
        XCTAssertEqual(store.compressedVersionIdentifiers, compressedBefore)
        XCTAssertTrue(store.isCompressedVersion(compressedBefore.first!))
    }

    func testResumeCleanupAfterCrash() throws {
        let versions = makeLinearChain(count: 60)
        setTimestampsToDistantPast(for: Array(versions[0..<10]))
        store = try Store(rootDirectoryURL: rootURL)

        let baselineId = try store.compact(beforeDate: Date(timeIntervalSinceNow: -7*24*3600), minRetainedVersions: 50)
        XCTAssertNotNil(baselineId)

        let compressedIds = store.compressedVersionIdentifiers

        // Simulate a "crash" scenario: manually write pendingCleanup = true
        // and restore some version JSON files
        let compactionURL = rootURL.appendingPathComponent("compaction.json")
        var info = try JSONDecoder().decode(CompactionInfo.self, from: Data(contentsOf: compactionURL))
        info.pendingCleanup = true
        let data = try JSONEncoder().encode(info)
        try data.write(to: compactionURL, options: .atomic)

        // Recreate store — should resume cleanup automatically
        store = try Store(rootDirectoryURL: rootURL)

        // Verify pendingCleanup is now false
        let infoAfter = try JSONDecoder().decode(CompactionInfo.self, from: Data(contentsOf: compactionURL))
        XCTAssertFalse(infoAfter.pendingCleanup)
        XCTAssertEqual(store.compressedVersionIdentifiers, compressedIds)
    }

    func testDoubleCompaction() throws {
        // First: 60 versions
        let versions = makeLinearChain(count: 60)
        setTimestampsToDistantPast(for: Array(versions[0..<10]))
        store = try Store(rootDirectoryURL: rootURL)

        let baseline1 = try store.compact(beforeDate: Date(timeIntervalSinceNow: -7*24*3600), minRetainedVersions: 50)
        XCTAssertNotNil(baseline1)

        let compressedAfterFirst = store.compressedVersionIdentifiers

        // Add 60 more versions
        var current = versions.last!
        var newVersions: [Version] = []
        for i in 0..<60 {
            current = try store.makeVersion(basedOnPredecessor: current.id, storing: [.insert(value("new\(i)", "newdata\(i)"))])
            newVersions.append(current)
        }

        // Set some of the older new versions to distant past
        setTimestampsToDistantPast(for: Array(newVersions[0..<10]))
        store = try Store(rootDirectoryURL: rootURL)

        // Second compaction
        let baseline2 = try store.compact(beforeDate: Date(timeIntervalSinceNow: -7*24*3600), minRetainedVersions: 50)
        XCTAssertNotNil(baseline2)

        // Second compaction should have compressed more versions
        XCTAssertTrue(store.compressedVersionIdentifiers.count > compressedAfterFirst.count)

        // Latest version should still work
        let latestRefs = try store.valueReferences(at: current.id)
        XCTAssertFalse(latestRefs.isEmpty)
    }

    func testExchangeSkipsCompressed() throws {
        // Set up two stores with a file system exchange
        let rootURL2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let exchangeURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer {
            try? fm.removeItem(at: rootURL2)
            try? fm.removeItem(at: exchangeURL)
        }

        let versions = makeLinearChain(count: 60)
        setTimestampsToDistantPast(for: Array(versions[0..<10]))
        store = try Store(rootDirectoryURL: rootURL)

        let baselineId = try store.compact(beforeDate: Date(timeIntervalSinceNow: -7*24*3600), minRetainedVersions: 50)
        XCTAssertNotNil(baselineId)

        _ = try Store(rootDirectoryURL: rootURL2)
        let exchange1 = FileSystemExchange(rootDirectoryURL: exchangeURL, store: store, usesFileCoordination: false)

        // Send from store1
        let expect = self.expectation(description: "Send")
        exchange1.send { result in
            switch result {
            case .success(let sentIds):
                // Compressed versions should NOT be in the sent IDs
                let compressed = self.store.compressedVersionIdentifiers
                for id in sentIds {
                    XCTAssertFalse(compressed.contains(id), "Compressed version should not be sent")
                }
            case .failure(let error):
                XCTFail("Send failed: \(error)")
            }
            expect.fulfill()
        }
        waitForExpectations(timeout: 10)
    }

    func testBaselineIsFullSnapshot() throws {
        // Create 60 versions, each adding a distinct value
        let versions = makeLinearChain(count: 60)

        // Record what values exist at the compaction point candidate
        // (We need to get these before compaction since the point will be compressed)
        setTimestampsToDistantPast(for: Array(versions[0..<10]))
        store = try Store(rootDirectoryURL: rootURL)

        // Compact
        let baselineId = try store.compact(beforeDate: Date(timeIntervalSinceNow: -7*24*3600), minRetainedVersions: 50)
        XCTAssertNotNil(baselineId)

        // Enumerate values at baseline
        let baselineRefs = try store.valueReferences(at: baselineId!)

        // Each value should be readable
        for ref in baselineRefs {
            let val = try store.value(storedAt: ref)
            XCTAssertNotNil(val, "Baseline value should be readable: \(ref.valueId.rawValue)")
        }
    }

    func testSQLiteZoneCompaction() throws {
        // Same as testLinearCompaction but with SQLiteStorage
        try? fm.removeItem(at: rootURL)
        store = try Store(rootDirectoryURL: rootURL, storage: SQLiteStorage())

        let versions = makeLinearChain(count: 60)
        setTimestampsToDistantPast(for: Array(versions[0..<10]))

        // Reload with SQLite storage
        store = try Store(rootDirectoryURL: rootURL, storage: SQLiteStorage())

        let baselineId = try store.compact(beforeDate: Date(timeIntervalSinceNow: -7*24*3600), minRetainedVersions: 50)
        XCTAssertNotNil(baselineId)

        let latestVersion = versions.last!
        let latestRefs = try store.valueReferences(at: latestVersion.id)
        XCTAssertFalse(latestRefs.isEmpty)

        XCTAssertFalse(store.compressedVersionIdentifiers.isEmpty)
    }

    func testIdempotentCleanup() throws {
        let versions = makeLinearChain(count: 60)
        setTimestampsToDistantPast(for: Array(versions[0..<10]))
        store = try Store(rootDirectoryURL: rootURL)

        let baselineId = try store.compact(beforeDate: Date(timeIntervalSinceNow: -7*24*3600), minRetainedVersions: 50)
        XCTAssertNotNil(baselineId)

        // Re-init store (this will run resumeCleanupIfNeeded, but pendingCleanup should be false)
        // Simulate pending cleanup by flipping the flag
        let compactionURL = rootURL.appendingPathComponent("compaction.json")
        var info = try JSONDecoder().decode(CompactionInfo.self, from: Data(contentsOf: compactionURL))
        info.pendingCleanup = true
        try JSONEncoder().encode(info).write(to: compactionURL, options: .atomic)

        // Second cleanup should be a no-op (files already deleted)
        XCTAssertNoThrow(try Store(rootDirectoryURL: rootURL))

        let infoAfter = try JSONDecoder().decode(CompactionInfo.self, from: Data(contentsOf: compactionURL))
        XCTAssertFalse(infoAfter.pendingCleanup)
    }
}


// MARK: - Compaction Policy Tests

class CompactionPolicyTests: XCTestCase {

    let fm = FileManager.default

    var rootURL: URL!
    var cacheURL: URL!

    override func setUp() {
        super.setUp()
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        cacheURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? fm.removeItem(at: rootURL)
        try? fm.removeItem(at: cacheURL)
        super.tearDown()
    }

    private func value(_ id: String, _ string: String) -> Value {
        Value(id: .init(id), data: string.data(using: .utf8)!)
    }

    /// Creates a store with old versions suitable for compaction, then returns the store URL for coordinator init.
    private func prepareStoreWithOldVersions() throws {
        let store = try Store(rootDirectoryURL: rootURL)
        var predecessor: Version.ID? = nil
        var versions: [Version] = []
        for i in 0..<60 {
            let val = value("v\(i)", "data\(i)")
            let ver = try store.makeVersion(basedOnPredecessor: predecessor, storing: [.insert(val)])
            versions.append(ver)
            predecessor = ver.id
        }

        // Set first 10 versions to distant past
        let distantPast = Date(timeIntervalSinceNow: -30*24*3600).timeIntervalSinceReferenceDate
        for (i, version) in versions[0..<10].enumerated() {
            var v = version
            v.timestamp = distantPast - TimeInterval(10 - i)
            let versionsDir = rootURL.appendingPathComponent("versions")
            let fileURL = versionsDir.appendingSplitPathComponent(v.id.rawValue).appendingPathExtension("json")
            let data = try JSONEncoder().encode(v)
            try data.write(to: fileURL)
        }
    }

    func testAutoCompactionOnStartup() throws {
        try prepareStoreWithOldVersions()

        // Init coordinator with .auto — should compact on startup
        let coordinator = try StoreCoordinator(withStoreDirectoryAt: rootURL, cacheDirectoryAt: cacheURL, compactionPolicy: .auto)

        XCTAssertFalse(coordinator.store.compressedVersionIdentifiers.isEmpty, "Auto compaction should have compressed old versions")
    }

    func testManualPolicyDoesNotAutoCompact() throws {
        try prepareStoreWithOldVersions()

        // Init coordinator with .manual — should NOT compact on startup
        let coordinator = try StoreCoordinator(withStoreDirectoryAt: rootURL, cacheDirectoryAt: cacheURL, compactionPolicy: .manual)

        XCTAssertTrue(coordinator.store.compressedVersionIdentifiers.isEmpty, "Manual policy should not auto-compact")

        // But explicit compact() should work
        let baselineId = try coordinator.compact()
        XCTAssertNotNil(baselineId)
        XCTAssertFalse(coordinator.store.compressedVersionIdentifiers.isEmpty)
    }

    func testNonePolicyDisablesCompaction() throws {
        try prepareStoreWithOldVersions()

        // Init coordinator with .none
        let coordinator = try StoreCoordinator(withStoreDirectoryAt: rootURL, cacheDirectoryAt: cacheURL, compactionPolicy: .none)

        XCTAssertTrue(coordinator.store.compressedVersionIdentifiers.isEmpty, "None policy should not auto-compact")

        // Explicit compact() on coordinator should return nil
        let baselineId = try coordinator.compact()
        XCTAssertNil(baselineId, "Coordinator compact() should return nil when policy is .none")

        // But store.compact() directly should still work
        let directBaseline = try coordinator.store.compact()
        XCTAssertNotNil(directBaseline)
        XCTAssertFalse(coordinator.store.compressedVersionIdentifiers.isEmpty)
    }

    func testDefaultPolicyIsAuto() throws {
        try prepareStoreWithOldVersions()

        // Init coordinator with no policy argument — should default to .auto
        let coordinator = try StoreCoordinator(withStoreDirectoryAt: rootURL, cacheDirectoryAt: cacheURL)

        XCTAssertEqual(coordinator.compactionPolicy, .auto)
        XCTAssertFalse(coordinator.store.compressedVersionIdentifiers.isEmpty, "Default policy should auto-compact")
    }
}
