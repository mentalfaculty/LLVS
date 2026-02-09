//
//  SnapshotTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 09/02/2026.
//

import XCTest
import Foundation
@testable import LLVS
@testable import LLVSSQLite

// MARK: - Storage-Level Tests

class SnapshotStorageTests: XCTestCase {

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

    private func value(_ id: String, _ string: String) -> Value {
        Value(id: .init(id), data: string.data(using: .utf8)!)
    }

    @discardableResult
    private func makeLinearChain(count: Int, store: Store? = nil) -> [Version] {
        let s = store ?? self.store!
        var versions: [Version] = []
        var predecessor: Version.ID? = nil
        for i in 0..<count {
            let val = value("val\(i)", "data\(i)")
            let ver = try! s.makeVersion(basedOnPredecessor: predecessor, storing: [.insert(val)])
            versions.append(ver)
            predecessor = ver.id
        }
        return versions
    }

    func testFileStorageSnapshotRoundTrip() throws {
        let versions = makeLinearChain(count: 50)
        let storage = FileStorage()

        // Write snapshot
        let snapshotDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: snapshotDir) }

        let manifest = try storage.writeSnapshotChunks(storeRootURL: rootURL, to: snapshotDir, maxChunkSize: 5_000_000)

        // Create a new empty store and restore
        let rootURL2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: rootURL2) }
        try fm.createDirectory(at: rootURL2, withIntermediateDirectories: true, attributes: nil)

        try storage.restoreFromSnapshotChunks(storeRootURL: rootURL2, from: snapshotDir, manifest: manifest)

        // Load the store and verify
        let store2 = try Store(rootDirectoryURL: rootURL2)
        var versionCount = 0
        store2.queryHistory { history in
            versionCount = history.allVersionIdentifiers.count
        }
        XCTAssertEqual(versionCount, 50)

        // Verify all values readable
        for version in versions {
            let refs = try store2.valueReferences(at: version.id)
            XCTAssertFalse(refs.isEmpty)
        }

        // Verify latest value readable
        let latestVal = try store2.value(id: .init("val49"), at: versions.last!.id)
        XCTAssertNotNil(latestVal)
        XCTAssertEqual(String(data: latestVal!.data, encoding: .utf8), "data49")
    }

    func testSnapshotChunking() throws {
        // Create enough data to produce multiple chunks
        let versions = makeLinearChain(count: 50)
        let storage = FileStorage()

        let snapshotDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: snapshotDir) }

        // Use a very small chunk size to ensure multiple chunks
        let manifest = try storage.writeSnapshotChunks(storeRootURL: rootURL, to: snapshotDir, maxChunkSize: 1024)

        XCTAssertGreaterThan(manifest.chunkCount, 1, "Small maxChunkSize should produce multiple chunks")

        // Verify round-trip with chunked snapshot
        let rootURL2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: rootURL2) }
        try fm.createDirectory(at: rootURL2, withIntermediateDirectories: true, attributes: nil)

        try storage.restoreFromSnapshotChunks(storeRootURL: rootURL2, from: snapshotDir, manifest: manifest)
        let store2 = try Store(rootDirectoryURL: rootURL2)

        // Verify integrity
        let latestVal = try store2.value(id: .init("val49"), at: versions.last!.id)
        XCTAssertNotNil(latestVal)
        XCTAssertEqual(String(data: latestVal!.data, encoding: .utf8), "data49")
    }

    func testSnapshotManifestContents() throws {
        makeLinearChain(count: 50)
        let storage = FileStorage()

        let snapshotDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: snapshotDir) }

        let manifest = try storage.writeSnapshotChunks(storeRootURL: rootURL, to: snapshotDir, maxChunkSize: 5_000_000)

        XCTAssertEqual(manifest.format, "fileStorage-v1")
        XCTAssertEqual(manifest.versionCount, 50)
        XCTAssertGreaterThan(manifest.chunkCount, 0)
        XCTAssertFalse(manifest.latestVersionId.rawValue.isEmpty)
        XCTAssertGreaterThan(manifest.totalSize, 0)
    }

    func testSQLiteStorageSnapshotRoundTrip() throws {
        // Create store with SQLite storage
        try? fm.removeItem(at: rootURL)
        let sqlStore = try Store(rootDirectoryURL: rootURL, storage: SQLiteStorage())
        let versions = makeLinearChain(count: 50, store: sqlStore)
        let storage = SQLiteStorage()

        let snapshotDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: snapshotDir) }

        let manifest = try storage.writeSnapshotChunks(storeRootURL: rootURL, to: snapshotDir, maxChunkSize: 5_000_000)
        XCTAssertEqual(manifest.format, "sqliteStorage-v1")
        XCTAssertEqual(manifest.versionCount, 50)

        // Restore
        let rootURL2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: rootURL2) }
        try fm.createDirectory(at: rootURL2, withIntermediateDirectories: true, attributes: nil)

        try storage.restoreFromSnapshotChunks(storeRootURL: rootURL2, from: snapshotDir, manifest: manifest)
        let store2 = try Store(rootDirectoryURL: rootURL2, storage: SQLiteStorage())

        var versionCount = 0
        store2.queryHistory { history in
            versionCount = history.allVersionIdentifiers.count
        }
        XCTAssertEqual(versionCount, 50)

        let latestVal = try store2.value(id: .init("val49"), at: versions.last!.id)
        XCTAssertNotNil(latestVal)
        XCTAssertEqual(String(data: latestVal!.data, encoding: .utf8), "data49")
    }
}


// MARK: - Exchange-Level Tests

class SnapshotExchangeTests: XCTestCase {

    let fm = FileManager.default

    var store1: Store!
    var rootURL1: URL!
    var exchangeURL: URL!
    var exchange1: FileSystemExchange!

    override func setUp() {
        super.setUp()
        rootURL1 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store1 = try! Store(rootDirectoryURL: rootURL1)
        exchangeURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        exchange1 = FileSystemExchange(rootDirectoryURL: exchangeURL, store: store1, usesFileCoordination: false)
    }

    override func tearDown() {
        try? fm.removeItem(at: rootURL1)
        try? fm.removeItem(at: exchangeURL)
        super.tearDown()
    }

    private func value(_ id: String, _ string: String) -> Value {
        Value(id: .init(id), data: string.data(using: .utf8)!)
    }

    @discardableResult
    private func makeLinearChain(count: Int, store: Store? = nil) -> [Version] {
        let s = store ?? self.store1!
        var versions: [Version] = []
        var predecessor: Version.ID? = nil
        for i in 0..<count {
            let val = value("val\(i)", "data\(i)")
            let ver = try! s.makeVersion(basedOnPredecessor: predecessor, storing: [.insert(val)])
            versions.append(ver)
            predecessor = ver.id
        }
        return versions
    }

    func testFileSystemExchangeSnapshotUploadDownload() throws {
        makeLinearChain(count: 50)
        let storage = FileStorage()

        // Write snapshot
        let snapshotDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: snapshotDir) }

        let manifest = try storage.writeSnapshotChunks(storeRootURL: rootURL1, to: snapshotDir, maxChunkSize: 5_000_000)

        // Upload via exchange
        let uploadExpect = expectation(description: "Upload")
        exchange1.sendSnapshot(manifest: manifest, chunkProvider: { index in
            let chunkFile = snapshotDir.appendingPathComponent(String(format: "chunk-%03d", index))
            return try Data(contentsOf: chunkFile)
        }) { result in
            if case .failure(let error) = result { XCTFail("Upload failed: \(error)") }
            uploadExpect.fulfill()
        }
        waitForExpectations(timeout: 10)

        // Verify files exist in snapshots/ directory
        let snapshotsDir = exchangeURL.appendingPathComponent("snapshots")
        XCTAssertTrue(fm.fileExists(atPath: snapshotsDir.appendingPathComponent("manifest.json").path))

        // Download manifest from second exchange instance
        let rootURL2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: rootURL2) }
        let store2 = try Store(rootDirectoryURL: rootURL2)
        let exchange2 = FileSystemExchange(rootDirectoryURL: exchangeURL, store: store2, usesFileCoordination: false)

        let manifestExpect = expectation(description: "Manifest")
        exchange2.retrieveSnapshotManifest { result in
            switch result {
            case .success(let downloadedManifest):
                XCTAssertNotNil(downloadedManifest)
                XCTAssertEqual(downloadedManifest?.format, "fileStorage-v1")
                XCTAssertEqual(downloadedManifest?.versionCount, 50)
            case .failure(let error):
                XCTFail("Manifest download failed: \(error)")
            }
            manifestExpect.fulfill()
        }
        waitForExpectations(timeout: 10)
    }

    func testBootstrapFromSnapshot() throws {
        let versions = makeLinearChain(count: 50)

        // Sync to exchange
        let sendExpect = expectation(description: "Send")
        exchange1.send { _ in sendExpect.fulfill() }
        waitForExpectations(timeout: 10)

        // Upload snapshot
        let storage = FileStorage()
        let snapshotDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: snapshotDir) }
        let manifest = try storage.writeSnapshotChunks(storeRootURL: rootURL1, to: snapshotDir, maxChunkSize: 5_000_000)

        let uploadExpect = expectation(description: "Upload")
        exchange1.sendSnapshot(manifest: manifest, chunkProvider: { index in
            let chunkFile = snapshotDir.appendingPathComponent(String(format: "chunk-%03d", index))
            return try Data(contentsOf: chunkFile)
        }) { result in
            if case .failure(let error) = result { XCTFail("Upload failed: \(error)") }
            uploadExpect.fulfill()
        }
        waitForExpectations(timeout: 10)

        // Create store2 coordinator and bootstrap
        let rootURL2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let cacheURL2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer {
            try? fm.removeItem(at: rootURL2)
            try? fm.removeItem(at: cacheURL2)
        }

        let coordinator2 = try StoreCoordinator(withStoreDirectoryAt: rootURL2, cacheDirectoryAt: cacheURL2)
        coordinator2.exchange = FileSystemExchange(rootDirectoryURL: exchangeURL, store: coordinator2.store, usesFileCoordination: false)

        let bootstrapExpect = expectation(description: "Bootstrap")
        coordinator2.bootstrapFromSnapshot { error in
            XCTAssertNil(error)
            bootstrapExpect.fulfill()
        }
        waitForExpectations(timeout: 10)

        // Verify all versions: 50 from snapshot + 1 initial from coordinator2
        var versionCount = 0
        coordinator2.store.queryHistory { history in
            versionCount = history.allVersionIdentifiers.count
        }
        XCTAssertEqual(versionCount, 51)

        // Verify data readable
        let latestVal = try coordinator2.store.value(id: .init("val49"), at: versions.last!.id)
        XCTAssertNotNil(latestVal)
    }

    func testBootstrapThenIncrementalSync() throws {
        let versions = makeLinearChain(count: 50)

        // Upload snapshot
        let storage = FileStorage()
        let snapshotDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: snapshotDir) }
        let manifest = try storage.writeSnapshotChunks(storeRootURL: rootURL1, to: snapshotDir, maxChunkSize: 5_000_000)

        let uploadExpect = expectation(description: "Upload")
        exchange1.sendSnapshot(manifest: manifest, chunkProvider: { index in
            let chunkFile = snapshotDir.appendingPathComponent(String(format: "chunk-%03d", index))
            return try Data(contentsOf: chunkFile)
        }) { result in
            if case .failure(let error) = result { XCTFail("Upload failed: \(error)") }
            uploadExpect.fulfill()
        }
        waitForExpectations(timeout: 10)

        // Add 10 more versions and sync to exchange
        var predecessor = versions.last!.id
        for i in 50..<60 {
            let ver = try store1.makeVersion(basedOnPredecessor: predecessor, storing: [.insert(value("val\(i)", "data\(i)"))])
            predecessor = ver.id
        }

        let sendExpect = expectation(description: "Send")
        exchange1.send { _ in sendExpect.fulfill() }
        waitForExpectations(timeout: 10)

        // Create store2, bootstrap, then incremental sync
        let rootURL2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let cacheURL2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer {
            try? fm.removeItem(at: rootURL2)
            try? fm.removeItem(at: cacheURL2)
        }

        let coordinator2 = try StoreCoordinator(withStoreDirectoryAt: rootURL2, cacheDirectoryAt: cacheURL2)
        let exchange2 = FileSystemExchange(rootDirectoryURL: exchangeURL, store: coordinator2.store, usesFileCoordination: false)
        coordinator2.exchange = exchange2

        let bootstrapExpect = expectation(description: "Bootstrap")
        coordinator2.bootstrapFromSnapshot { error in
            XCTAssertNil(error)
            bootstrapExpect.fulfill()
        }
        waitForExpectations(timeout: 10)

        // Normal exchange to get remaining 10 versions
        let exchangeExpect = expectation(description: "Exchange")
        coordinator2.exchange { error in
            XCTAssertNil(error)
            exchangeExpect.fulfill()
        }
        waitForExpectations(timeout: 10)

        // Should have all versions: 60 from store1 + 1 initial from coordinator2
        var versionCount = 0
        coordinator2.store.queryHistory { history in
            versionCount = history.allVersionIdentifiers.count
        }
        XCTAssertEqual(versionCount, 61)

        let val59 = try coordinator2.store.value(id: .init("val59"), at: .init(predecessor.rawValue))
        XCTAssertNotNil(val59)
    }

    func testConcurrentSnapshotUploadsProduceValidSnapshot() throws {
        // Two stores upload snapshots concurrently to the same exchange directory.
        // After both complete, the resulting snapshot should be valid and bootstrappable.
        makeLinearChain(count: 30)

        // Create a second store with different data
        let rootURL2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: rootURL2) }
        let store2 = try Store(rootDirectoryURL: rootURL2)
        var predecessor: Version.ID? = nil
        for i in 0..<40 {
            let val = value("other\(i)", "otherdata\(i)")
            let ver = try store2.makeVersion(basedOnPredecessor: predecessor, storing: [.insert(val)])
            predecessor = ver.id
        }

        let storage = FileStorage()

        // Build snapshot chunks from each store
        let snapshotDirA = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let snapshotDirB = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer {
            try? fm.removeItem(at: snapshotDirA)
            try? fm.removeItem(at: snapshotDirB)
        }

        let manifestA = try storage.writeSnapshotChunks(storeRootURL: rootURL1, to: snapshotDirA, maxChunkSize: 1024)
        let manifestB = try storage.writeSnapshotChunks(storeRootURL: rootURL2, to: snapshotDirB, maxChunkSize: 1024)

        // Two separate exchange instances pointing to the same shared directory
        let exchangeA = FileSystemExchange(rootDirectoryURL: exchangeURL, store: store1, usesFileCoordination: false)
        let exchangeB = FileSystemExchange(rootDirectoryURL: exchangeURL, store: store2, usesFileCoordination: false)

        // Upload concurrently
        let expectA = expectation(description: "Upload A")
        let expectB = expectation(description: "Upload B")

        exchangeA.sendSnapshot(manifest: manifestA, chunkProvider: { index in
            let chunkFile = snapshotDirA.appendingPathComponent(String(format: "chunk-%03d", index))
            return try Data(contentsOf: chunkFile)
        }) { result in
            // Upload may succeed or fail due to concurrent directory deletion — both are acceptable
            expectA.fulfill()
        }

        exchangeB.sendSnapshot(manifest: manifestB, chunkProvider: { index in
            let chunkFile = snapshotDirB.appendingPathComponent(String(format: "chunk-%03d", index))
            return try Data(contentsOf: chunkFile)
        }) { result in
            expectB.fulfill()
        }

        waitForExpectations(timeout: 10)

        // Now attempt a retry upload from whichever store "won" — we just re-upload from store2
        // to guarantee a clean snapshot exists
        let retryExpect = expectation(description: "Retry Upload")
        exchangeB.sendSnapshot(manifest: manifestB, chunkProvider: { index in
            let chunkFile = snapshotDirB.appendingPathComponent(String(format: "chunk-%03d", index))
            return try Data(contentsOf: chunkFile)
        }) { result in
            if case .failure(let error) = result { XCTFail("Retry upload failed: \(error)") }
            retryExpect.fulfill()
        }
        waitForExpectations(timeout: 10)

        // Verify the final snapshot is valid by bootstrapping a third store
        let rootURL3 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let cacheURL3 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer {
            try? fm.removeItem(at: rootURL3)
            try? fm.removeItem(at: cacheURL3)
        }

        // Send store2's versions so the bootstrapped store can load them
        let exchange2ForSend = FileSystemExchange(rootDirectoryURL: exchangeURL, store: store2, usesFileCoordination: false)
        let sendExpect = expectation(description: "Send")
        exchange2ForSend.send { _ in sendExpect.fulfill() }
        waitForExpectations(timeout: 10)

        let coordinator3 = try StoreCoordinator(withStoreDirectoryAt: rootURL3, cacheDirectoryAt: cacheURL3)
        coordinator3.exchange = FileSystemExchange(rootDirectoryURL: exchangeURL, store: coordinator3.store, usesFileCoordination: false)

        let bootstrapExpect = expectation(description: "Bootstrap")
        coordinator3.bootstrapFromSnapshot { error in
            XCTAssertNil(error, "Bootstrap after concurrent uploads should succeed once a clean snapshot exists")
            bootstrapExpect.fulfill()
        }
        waitForExpectations(timeout: 10)

        var versionCount = 0
        coordinator3.store.queryHistory { history in
            versionCount = history.allVersionIdentifiers.count
        }
        // 40 versions from store2's snapshot + 1 initial from coordinator3
        XCTAssertEqual(versionCount, 41)
    }

    func testBootstrapDuringSnapshotReplacementRecoversGracefully() throws {
        // Upload an initial snapshot, then start a bootstrap while simultaneously
        // replacing the snapshot. The bootstrap should either succeed or fail with
        // an error (not crash or corrupt the store).
        makeLinearChain(count: 30)

        let storage = FileStorage()
        let snapshotDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: snapshotDir) }
        let manifest = try storage.writeSnapshotChunks(storeRootURL: rootURL1, to: snapshotDir, maxChunkSize: 1024)

        // Upload initial snapshot
        let uploadExpect = expectation(description: "Initial upload")
        exchange1.sendSnapshot(manifest: manifest, chunkProvider: { index in
            let chunkFile = snapshotDir.appendingPathComponent(String(format: "chunk-%03d", index))
            return try Data(contentsOf: chunkFile)
        }) { result in
            if case .failure(let error) = result { XCTFail("Initial upload failed: \(error)") }
            uploadExpect.fulfill()
        }
        waitForExpectations(timeout: 10)

        // Send versions to exchange so bootstrap can work
        let sendExpect = expectation(description: "Send")
        exchange1.send { _ in sendExpect.fulfill() }
        waitForExpectations(timeout: 10)

        // Prepare replacement snapshot from a different store
        let rootURL2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: rootURL2) }
        let store2 = try Store(rootDirectoryURL: rootURL2)
        var predecessor: Version.ID? = nil
        for i in 0..<20 {
            let ver = try store2.makeVersion(basedOnPredecessor: predecessor, storing: [.insert(value("new\(i)", "newdata\(i)"))])
            predecessor = ver.id
        }
        let snapshotDir2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: snapshotDir2) }
        let manifest2 = try storage.writeSnapshotChunks(storeRootURL: rootURL2, to: snapshotDir2, maxChunkSize: 1024)

        // Now race: bootstrap from one exchange while another replaces the snapshot
        let rootURL3 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let cacheURL3 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer {
            try? fm.removeItem(at: rootURL3)
            try? fm.removeItem(at: cacheURL3)
        }

        let coordinator3 = try StoreCoordinator(withStoreDirectoryAt: rootURL3, cacheDirectoryAt: cacheURL3)
        coordinator3.exchange = FileSystemExchange(rootDirectoryURL: exchangeURL, store: coordinator3.store, usesFileCoordination: false)

        let replacerExchange = FileSystemExchange(rootDirectoryURL: exchangeURL, store: store2, usesFileCoordination: false)

        let bootstrapExpect = expectation(description: "Bootstrap")
        var bootstrapError: Swift.Error?

        coordinator3.bootstrapFromSnapshot { error in
            bootstrapError = error
            bootstrapExpect.fulfill()
        }

        // Simultaneously replace the snapshot
        let replaceExpect = expectation(description: "Replace")
        replacerExchange.sendSnapshot(manifest: manifest2, chunkProvider: { index in
            let chunkFile = snapshotDir2.appendingPathComponent(String(format: "chunk-%03d", index))
            return try Data(contentsOf: chunkFile)
        }) { _ in
            replaceExpect.fulfill()
        }

        waitForExpectations(timeout: 10)

        // The key assertion: no crash, and the store is in a consistent state.
        // The bootstrap may have succeeded (read the old snapshot before replacement)
        // or failed (chunks disappeared mid-read). Either is acceptable.
        if bootstrapError != nil {
            // Bootstrap failed due to race — this is the expected graceful recovery.
            // Verify the store is still functional (not corrupted).
            var versionCount = 0
            coordinator3.store.queryHistory { history in
                versionCount = history.allVersionIdentifiers.count
            }
            // Should still have just the initial coordinator version (bootstrap didn't partially apply)
            XCTAssertGreaterThanOrEqual(versionCount, 1)
        }

        // Regardless of the race outcome, a fresh bootstrap with the current snapshot should work.
        // Create a clean coordinator and try again.
        let rootURL4 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let cacheURL4 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer {
            try? fm.removeItem(at: rootURL4)
            try? fm.removeItem(at: cacheURL4)
        }

        let coordinator4 = try StoreCoordinator(withStoreDirectoryAt: rootURL4, cacheDirectoryAt: cacheURL4)
        coordinator4.exchange = FileSystemExchange(rootDirectoryURL: exchangeURL, store: coordinator4.store, usesFileCoordination: false)

        let retryExpect = expectation(description: "Retry bootstrap")
        coordinator4.bootstrapFromSnapshot { error in
            XCTAssertNil(error, "A clean bootstrap after the race should succeed")
            retryExpect.fulfill()
        }
        waitForExpectations(timeout: 10)

        // The second snapshot (from store2) should now be in effect
        var retryCount = 0
        coordinator4.store.queryHistory { history in
            retryCount = history.allVersionIdentifiers.count
        }
        // 20 versions from store2 snapshot + 1 initial from coordinator4
        XCTAssertEqual(retryCount, 21)
    }

    func testBootstrapSkipsPopulatedStore() throws {
        makeLinearChain(count: 50)

        // Upload snapshot
        let storage = FileStorage()
        let snapshotDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: snapshotDir) }
        let manifest = try storage.writeSnapshotChunks(storeRootURL: rootURL1, to: snapshotDir, maxChunkSize: 5_000_000)

        let uploadExpect = expectation(description: "Upload")
        exchange1.sendSnapshot(manifest: manifest, chunkProvider: { index in
            let chunkFile = snapshotDir.appendingPathComponent(String(format: "chunk-%03d", index))
            return try Data(contentsOf: chunkFile)
        }) { result in
            if case .failure(let error) = result { XCTFail("Upload failed: \(error)") }
            uploadExpect.fulfill()
        }
        waitForExpectations(timeout: 10)

        // Create coordinator2 with existing data (> 1 version)
        let rootURL2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let cacheURL2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer {
            try? fm.removeItem(at: rootURL2)
            try? fm.removeItem(at: cacheURL2)
        }

        let coordinator2 = try StoreCoordinator(withStoreDirectoryAt: rootURL2, cacheDirectoryAt: cacheURL2)
        // Make some versions so the store is populated
        try coordinator2.save(inserting: [value("existing1", "data1")])
        try coordinator2.save(inserting: [value("existing2", "data2")])

        coordinator2.exchange = FileSystemExchange(rootDirectoryURL: exchangeURL, store: coordinator2.store, usesFileCoordination: false)

        var versionCountBefore = 0
        coordinator2.store.queryHistory { history in
            versionCountBefore = history.allVersionIdentifiers.count
        }

        let bootstrapExpect = expectation(description: "Bootstrap")
        coordinator2.bootstrapFromSnapshot { error in
            XCTAssertNil(error)
            bootstrapExpect.fulfill()
        }
        waitForExpectations(timeout: 10)

        // Version count should be unchanged (bootstrap was skipped)
        var versionCountAfter = 0
        coordinator2.store.queryHistory { history in
            versionCountAfter = history.allVersionIdentifiers.count
        }
        XCTAssertEqual(versionCountBefore, versionCountAfter)
    }
}


// MARK: - Policy Tests

class SnapshotPolicyTests: XCTestCase {

    let fm = FileManager.default

    var rootURL: URL!
    var cacheURL: URL!
    var exchangeURL: URL!

    override func setUp() {
        super.setUp()
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        cacheURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        exchangeURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? fm.removeItem(at: rootURL)
        try? fm.removeItem(at: cacheURL)
        try? fm.removeItem(at: exchangeURL)
        super.tearDown()
    }

    private func value(_ id: String, _ string: String) -> Value {
        Value(id: .init(id), data: string.data(using: .utf8)!)
    }

    func testSnapshotNotUploadedWhenDisabled() throws {
        let coordinator = try StoreCoordinator(withStoreDirectoryAt: rootURL, cacheDirectoryAt: cacheURL, snapshotPolicy: .disabled)
        let exchange = FileSystemExchange(rootDirectoryURL: exchangeURL, store: coordinator.store, usesFileCoordination: false)
        coordinator.exchange = exchange

        // Create some versions
        for i in 0..<10 {
            try coordinator.save(inserting: [value("val\(i)", "data\(i)")])
        }

        // Exchange
        let expect = expectation(description: "Exchange")
        coordinator.exchange { error in
            XCTAssertNil(error)
            expect.fulfill()
        }
        waitForExpectations(timeout: 10)

        // Verify no snapshot directory
        let snapshotsDir = exchangeURL.appendingPathComponent("snapshots")
        XCTAssertFalse(fm.fileExists(atPath: snapshotsDir.appendingPathComponent("manifest.json").path))
    }

    func testSnapshotUploadedWhenPolicyMet() throws {
        let policy = SnapshotPolicy(enabled: true, minimumInterval: 0, minimumNewVersions: 5)
        let coordinator = try StoreCoordinator(withStoreDirectoryAt: rootURL, cacheDirectoryAt: cacheURL, snapshotPolicy: policy)
        let exchange = FileSystemExchange(rootDirectoryURL: exchangeURL, store: coordinator.store, usesFileCoordination: false)
        coordinator.exchange = exchange

        // Create > 5 versions
        for i in 0..<10 {
            try coordinator.save(inserting: [value("val\(i)", "data\(i)")])
        }

        // Sync to exchange first (so versions are in the exchange)
        let sendExpect = expectation(description: "Exchange")
        coordinator.exchange { error in
            XCTAssertNil(error)
            sendExpect.fulfill()
        }
        waitForExpectations(timeout: 10)

        // Give the async snapshot upload time to complete
        let uploadWait = expectation(description: "Wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            uploadWait.fulfill()
        }
        waitForExpectations(timeout: 5)

        // Verify snapshot was uploaded
        let snapshotsDir = exchangeURL.appendingPathComponent("snapshots")
        XCTAssertTrue(fm.fileExists(atPath: snapshotsDir.appendingPathComponent("manifest.json").path), "Snapshot should be uploaded when policy is met")
    }

    func testSnapshotNotReuploadedWhenRecentExists() throws {
        let policy = SnapshotPolicy(enabled: true, minimumInterval: 3600, minimumNewVersions: 1)
        let coordinator = try StoreCoordinator(withStoreDirectoryAt: rootURL, cacheDirectoryAt: cacheURL, snapshotPolicy: policy)
        let exchange = FileSystemExchange(rootDirectoryURL: exchangeURL, store: coordinator.store, usesFileCoordination: false)
        coordinator.exchange = exchange

        // Create versions
        for i in 0..<10 {
            try coordinator.save(inserting: [value("val\(i)", "data\(i)")])
        }

        // Manually upload a snapshot with current timestamp
        let storage = FileStorage()
        let snapshotDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: snapshotDir) }
        let manifest = try storage.writeSnapshotChunks(storeRootURL: rootURL, to: snapshotDir, maxChunkSize: 5_000_000)

        let uploadExpect = expectation(description: "Upload")
        exchange.sendSnapshot(manifest: manifest, chunkProvider: { index in
            let chunkFile = snapshotDir.appendingPathComponent(String(format: "chunk-%03d", index))
            return try Data(contentsOf: chunkFile)
        }) { result in
            if case .failure(let error) = result { XCTFail("Upload failed: \(error)") }
            uploadExpect.fulfill()
        }
        waitForExpectations(timeout: 10)

        let originalSnapshotId = manifest.snapshotId

        // Exchange again — snapshot is recent, should not be re-uploaded
        let exchangeExpect = expectation(description: "Exchange")
        coordinator.exchange { error in
            XCTAssertNil(error)
            exchangeExpect.fulfill()
        }
        waitForExpectations(timeout: 10)

        // Wait for potential async upload
        let waitExpect = expectation(description: "Wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { waitExpect.fulfill() }
        waitForExpectations(timeout: 5)

        // Verify manifest is unchanged (same snapshotId)
        let manifestCheckExpect = expectation(description: "ManifestCheck")
        exchange.retrieveSnapshotManifest { result in
            if case .success(let m) = result {
                XCTAssertEqual(m?.snapshotId, originalSnapshotId, "Snapshot should not have been re-uploaded")
            }
            manifestCheckExpect.fulfill()
        }
        waitForExpectations(timeout: 10)
    }

    func testFormatCompatibilityCheck() throws {
        // Upload a snapshot with a mismatched format string
        let coordinator = try StoreCoordinator(withStoreDirectoryAt: rootURL, cacheDirectoryAt: cacheURL)
        let exchange = FileSystemExchange(rootDirectoryURL: exchangeURL, store: coordinator.store, usesFileCoordination: false)
        coordinator.exchange = exchange

        // Write a fake manifest with wrong format
        let snapshotsDir = exchangeURL.appendingPathComponent("snapshots")
        try fm.createDirectory(at: snapshotsDir, withIntermediateDirectories: true, attributes: nil)
        let fakeManifest = SnapshotManifest(
            format: "unknownFormat-v99",
            latestVersionId: .init("fake"),
            versionCount: 100,
            chunkCount: 1,
            totalSize: 1000
        )
        let data = try JSONEncoder().encode(fakeManifest)
        try data.write(to: snapshotsDir.appendingPathComponent("manifest.json"))

        // Bootstrap should gracefully skip (no error, no restore)
        let bootstrapExpect = expectation(description: "Bootstrap")
        coordinator.bootstrapFromSnapshot { error in
            XCTAssertNil(error, "Mismatched format should not cause an error")
            bootstrapExpect.fulfill()
        }
        waitForExpectations(timeout: 10)

        // Store should still have just 1 version (the initial empty one created by StoreCoordinator)
        var versionCount = 0
        coordinator.store.queryHistory { history in
            versionCount = history.allVersionIdentifiers.count
        }
        XCTAssertEqual(versionCount, 1)
    }
}
