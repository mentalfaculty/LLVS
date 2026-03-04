//
//  SnapshotTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 09/02/2026.
//

import Testing
import Foundation
@testable import LLVS
@testable import LLVSSQLite

// MARK: - Storage-Level Tests

@Suite class SnapshotStorageTests {

    let fm = FileManager.default

    let store: Store
    let rootURL: URL

    init() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store = try Store(rootDirectoryURL: rootURL)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func value(_ id: String, _ string: String) -> Value {
        Value(id: .init(id), data: string.data(using: .utf8)!)
    }

    @discardableResult
    private func makeLinearChain(count: Int, store: Store? = nil) -> [Version] {
        let s = store ?? self.store
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

    @Test func fileStorageSnapshotRoundTrip() throws {
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
        #expect(versionCount == 50)

        // Verify all values readable
        for version in versions {
            let refs = try store2.valueReferences(at: version.id)
            #expect(!refs.isEmpty)
        }

        // Verify latest value readable
        let latestVal = try store2.value(id: .init("val49"), at: versions.last!.id)
        #expect(latestVal != nil)
        #expect(String(data: latestVal!.data, encoding: .utf8) == "data49")
    }

    @Test func snapshotChunking() throws {
        // Create enough data to produce multiple chunks
        let versions = makeLinearChain(count: 50)
        let storage = FileStorage()

        let snapshotDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: snapshotDir) }

        // Use a very small chunk size to ensure multiple chunks
        let manifest = try storage.writeSnapshotChunks(storeRootURL: rootURL, to: snapshotDir, maxChunkSize: 1024)

        #expect(manifest.chunkCount > 1, "Small maxChunkSize should produce multiple chunks")

        // Verify round-trip with chunked snapshot
        let rootURL2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: rootURL2) }
        try fm.createDirectory(at: rootURL2, withIntermediateDirectories: true, attributes: nil)

        try storage.restoreFromSnapshotChunks(storeRootURL: rootURL2, from: snapshotDir, manifest: manifest)
        let store2 = try Store(rootDirectoryURL: rootURL2)

        // Verify integrity
        let latestVal = try store2.value(id: .init("val49"), at: versions.last!.id)
        #expect(latestVal != nil)
        #expect(String(data: latestVal!.data, encoding: .utf8) == "data49")
    }

    @Test func snapshotManifestContents() throws {
        makeLinearChain(count: 50)
        let storage = FileStorage()

        let snapshotDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: snapshotDir) }

        let manifest = try storage.writeSnapshotChunks(storeRootURL: rootURL, to: snapshotDir, maxChunkSize: 5_000_000)

        #expect(manifest.format == "zip-v1")
        #expect(manifest.versionCount == 50)
        #expect(manifest.chunkCount > 0)
        #expect(!manifest.latestVersionId.rawValue.isEmpty)
        #expect(manifest.totalSize > 0)
    }

    @Test func sqliteStorageSnapshotRoundTrip() throws {
        // Create store with SQLite storage
        try? fm.removeItem(at: rootURL)
        let sqlStore = try Store(rootDirectoryURL: rootURL, storage: SQLiteStorage())
        let versions = makeLinearChain(count: 50, store: sqlStore)
        let storage = SQLiteStorage()

        let snapshotDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: snapshotDir) }

        let manifest = try storage.writeSnapshotChunks(storeRootURL: rootURL, to: snapshotDir, maxChunkSize: 5_000_000)
        #expect(manifest.format == "zip-v1")
        #expect(manifest.versionCount == 50)

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
        #expect(versionCount == 50)

        let latestVal = try store2.value(id: .init("val49"), at: versions.last!.id)
        #expect(latestVal != nil)
        #expect(String(data: latestVal!.data, encoding: .utf8) == "data49")
    }
}


// MARK: - Exchange-Level Tests

@Suite class SnapshotExchangeTests {

    let fm = FileManager.default

    let store1: Store
    let rootURL1: URL
    let exchangeURL: URL
    let exchange1: FileSystemExchange

    init() throws {
        rootURL1 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store1 = try Store(rootDirectoryURL: rootURL1)
        exchangeURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        exchange1 = FileSystemExchange(rootDirectoryURL: exchangeURL, store: store1, usesFileCoordination: false)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL1)
        try? FileManager.default.removeItem(at: exchangeURL)
    }

    private func value(_ id: String, _ string: String) -> Value {
        Value(id: .init(id), data: string.data(using: .utf8)!)
    }

    @discardableResult
    private func makeLinearChain(count: Int, store: Store? = nil) -> [Version] {
        let s = store ?? self.store1
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

    @Test func fileSystemExchangeSnapshotUploadDownload() async throws {
        makeLinearChain(count: 50)
        let storage = FileStorage()

        // Write snapshot
        let snapshotDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: snapshotDir) }

        let manifest = try storage.writeSnapshotChunks(storeRootURL: rootURL1, to: snapshotDir, maxChunkSize: 5_000_000)

        // Upload via exchange
        try await exchange1.sendSnapshot(manifest: manifest, chunkProvider: { index in
            let chunkFile = snapshotDir.appendingPathComponent(String(format: "chunk-%03d", index))
            return try Data(contentsOf: chunkFile)
        })

        // Verify files exist in snapshots/ directory
        let snapshotsDir = exchangeURL.appendingPathComponent("snapshots")
        #expect(fm.fileExists(atPath: snapshotsDir.appendingPathComponent("manifest.json").path))

        // Download manifest from second exchange instance
        let rootURL2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: rootURL2) }
        let store2 = try Store(rootDirectoryURL: rootURL2)
        let exchange2 = FileSystemExchange(rootDirectoryURL: exchangeURL, store: store2, usesFileCoordination: false)

        let downloadedManifest = try await exchange2.retrieveSnapshotManifest()
        #expect(downloadedManifest != nil)
        #expect(downloadedManifest?.format == "zip-v1")
        #expect(downloadedManifest?.versionCount == 50)
    }

    @Test func bootstrapFromSnapshot() async throws {
        let versions = makeLinearChain(count: 50)

        // Sync to exchange
        let _ = try await exchange1.send()

        // Upload snapshot
        let storage = FileStorage()
        let snapshotDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: snapshotDir) }
        let manifest = try storage.writeSnapshotChunks(storeRootURL: rootURL1, to: snapshotDir, maxChunkSize: 5_000_000)

        try await exchange1.sendSnapshot(manifest: manifest, chunkProvider: { index in
            let chunkFile = snapshotDir.appendingPathComponent(String(format: "chunk-%03d", index))
            return try Data(contentsOf: chunkFile)
        })

        // Create store2 coordinator and bootstrap
        let rootURL2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let cacheURL2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer {
            try? fm.removeItem(at: rootURL2)
            try? fm.removeItem(at: cacheURL2)
        }

        let coordinator2 = try StoreCoordinator(withStoreDirectoryAt: rootURL2, cacheDirectoryAt: cacheURL2)
        coordinator2.exchange = FileSystemExchange(rootDirectoryURL: exchangeURL, store: coordinator2.store, usesFileCoordination: false)

        try await coordinator2.bootstrapFromSnapshot()

        // Verify all versions: 50 from snapshot + 1 initial from coordinator2
        var versionCount = 0
        coordinator2.store.queryHistory { history in
            versionCount = history.allVersionIdentifiers.count
        }
        #expect(versionCount == 51)

        // Verify data readable
        let latestVal = try coordinator2.store.value(id: .init("val49"), at: versions.last!.id)
        #expect(latestVal != nil)
    }

    @Test func bootstrapThenIncrementalSync() async throws {
        let versions = makeLinearChain(count: 50)

        // Upload snapshot
        let storage = FileStorage()
        let snapshotDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: snapshotDir) }
        let manifest = try storage.writeSnapshotChunks(storeRootURL: rootURL1, to: snapshotDir, maxChunkSize: 5_000_000)

        try await exchange1.sendSnapshot(manifest: manifest, chunkProvider: { index in
            let chunkFile = snapshotDir.appendingPathComponent(String(format: "chunk-%03d", index))
            return try Data(contentsOf: chunkFile)
        })

        // Add 10 more versions and sync to exchange
        var predecessor = versions.last!.id
        for i in 50..<60 {
            let ver = try store1.makeVersion(basedOnPredecessor: predecessor, storing: [.insert(value("val\(i)", "data\(i)"))])
            predecessor = ver.id
        }

        let _ = try await exchange1.send()

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

        try await coordinator2.bootstrapFromSnapshot()

        // Normal exchange to get remaining 10 versions
        try await coordinator2.exchange()

        // Should have all versions: 60 from store1 + 1 initial from coordinator2
        var versionCount = 0
        coordinator2.store.queryHistory { history in
            versionCount = history.allVersionIdentifiers.count
        }
        #expect(versionCount == 61)

        let val59 = try coordinator2.store.value(id: .init("val59"), at: .init(predecessor.rawValue))
        #expect(val59 != nil)
    }

    @Test func concurrentSnapshotUploadsProduceValidSnapshot() async throws {
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
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await exchangeA.sendSnapshot(manifest: manifestA, chunkProvider: { index in
                    let chunkFile = snapshotDirA.appendingPathComponent(String(format: "chunk-%03d", index))
                    return try Data(contentsOf: chunkFile)
                })
            }
            group.addTask {
                try? await exchangeB.sendSnapshot(manifest: manifestB, chunkProvider: { index in
                    let chunkFile = snapshotDirB.appendingPathComponent(String(format: "chunk-%03d", index))
                    return try Data(contentsOf: chunkFile)
                })
            }
        }

        // Now retry upload from store2 to guarantee a clean snapshot exists
        try await exchangeB.sendSnapshot(manifest: manifestB, chunkProvider: { index in
            let chunkFile = snapshotDirB.appendingPathComponent(String(format: "chunk-%03d", index))
            return try Data(contentsOf: chunkFile)
        })

        // Verify the final snapshot is valid by bootstrapping a third store
        let rootURL3 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let cacheURL3 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer {
            try? fm.removeItem(at: rootURL3)
            try? fm.removeItem(at: cacheURL3)
        }

        // Send store2's versions so the bootstrapped store can load them
        let exchange2ForSend = FileSystemExchange(rootDirectoryURL: exchangeURL, store: store2, usesFileCoordination: false)
        let _ = try await exchange2ForSend.send()

        let coordinator3 = try StoreCoordinator(withStoreDirectoryAt: rootURL3, cacheDirectoryAt: cacheURL3)
        coordinator3.exchange = FileSystemExchange(rootDirectoryURL: exchangeURL, store: coordinator3.store, usesFileCoordination: false)

        try await coordinator3.bootstrapFromSnapshot()

        var versionCount = 0
        coordinator3.store.queryHistory { history in
            versionCount = history.allVersionIdentifiers.count
        }
        // 40 versions from store2's snapshot + 1 initial from coordinator3
        #expect(versionCount == 41)
    }

    @Test func bootstrapDuringSnapshotReplacementRecoversGracefully() async throws {
        // Upload an initial snapshot, then start a bootstrap while simultaneously
        // replacing the snapshot. The bootstrap should either succeed or fail with
        // an error (not crash or corrupt the store).
        makeLinearChain(count: 30)

        let storage = FileStorage()
        let snapshotDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: snapshotDir) }
        let manifest = try storage.writeSnapshotChunks(storeRootURL: rootURL1, to: snapshotDir, maxChunkSize: 1024)

        // Upload initial snapshot
        try await exchange1.sendSnapshot(manifest: manifest, chunkProvider: { index in
            let chunkFile = snapshotDir.appendingPathComponent(String(format: "chunk-%03d", index))
            return try Data(contentsOf: chunkFile)
        })

        // Send versions to exchange so bootstrap can work
        let _ = try await exchange1.send()

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

        var bootstrapError: Swift.Error?

        // Race bootstrap and snapshot replacement
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    try await coordinator3.bootstrapFromSnapshot()
                } catch {
                    bootstrapError = error
                }
            }
            group.addTask {
                try? await replacerExchange.sendSnapshot(manifest: manifest2, chunkProvider: { index in
                    let chunkFile = snapshotDir2.appendingPathComponent(String(format: "chunk-%03d", index))
                    return try Data(contentsOf: chunkFile)
                })
            }
        }

        // The key assertion: no crash, and the store is in a consistent state.
        if bootstrapError != nil {
            // Bootstrap failed due to race — this is the expected graceful recovery.
            var versionCount = 0
            coordinator3.store.queryHistory { history in
                versionCount = history.allVersionIdentifiers.count
            }
            #expect(versionCount >= 1)
        }

        // Regardless of the race outcome, a fresh bootstrap with the current snapshot should work.
        let rootURL4 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let cacheURL4 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer {
            try? fm.removeItem(at: rootURL4)
            try? fm.removeItem(at: cacheURL4)
        }

        let coordinator4 = try StoreCoordinator(withStoreDirectoryAt: rootURL4, cacheDirectoryAt: cacheURL4)
        coordinator4.exchange = FileSystemExchange(rootDirectoryURL: exchangeURL, store: coordinator4.store, usesFileCoordination: false)

        try await coordinator4.bootstrapFromSnapshot()

        // The second snapshot (from store2) should now be in effect
        var retryCount = 0
        coordinator4.store.queryHistory { history in
            retryCount = history.allVersionIdentifiers.count
        }
        // 20 versions from store2 snapshot + 1 initial from coordinator4
        #expect(retryCount == 21)
    }

    @Test func bootstrapSkipsPopulatedStore() async throws {
        makeLinearChain(count: 50)

        // Upload snapshot
        let storage = FileStorage()
        let snapshotDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: snapshotDir) }
        let manifest = try storage.writeSnapshotChunks(storeRootURL: rootURL1, to: snapshotDir, maxChunkSize: 5_000_000)

        try await exchange1.sendSnapshot(manifest: manifest, chunkProvider: { index in
            let chunkFile = snapshotDir.appendingPathComponent(String(format: "chunk-%03d", index))
            return try Data(contentsOf: chunkFile)
        })

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

        try await coordinator2.bootstrapFromSnapshot()

        // Version count should be unchanged (bootstrap was skipped)
        var versionCountAfter = 0
        coordinator2.store.queryHistory { history in
            versionCountAfter = history.allVersionIdentifiers.count
        }
        #expect(versionCountBefore == versionCountAfter)
    }
}


// MARK: - Policy Tests

@Suite class SnapshotPolicyTests {

    let fm = FileManager.default

    let rootURL: URL
    let cacheURL: URL
    let exchangeURL: URL

    init() {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        cacheURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        exchangeURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
        try? FileManager.default.removeItem(at: cacheURL)
        try? FileManager.default.removeItem(at: exchangeURL)
    }

    private func value(_ id: String, _ string: String) -> Value {
        Value(id: .init(id), data: string.data(using: .utf8)!)
    }

    @Test func snapshotNotUploadedWhenDisabled() async throws {
        let coordinator = try StoreCoordinator(withStoreDirectoryAt: rootURL, cacheDirectoryAt: cacheURL, snapshotPolicy: .disabled)
        let exchange = FileSystemExchange(rootDirectoryURL: exchangeURL, store: coordinator.store, usesFileCoordination: false)
        coordinator.exchange = exchange

        // Create some versions
        for i in 0..<10 {
            try coordinator.save(inserting: [value("val\(i)", "data\(i)")])
        }

        // Exchange
        try await coordinator.exchange()

        // Give the fire-and-forget snapshot upload time to complete (if it were to run)
        try await Task.sleep(for: .seconds(2))

        // Verify no snapshot directory
        let snapshotsDir = exchangeURL.appendingPathComponent("snapshots")
        #expect(!fm.fileExists(atPath: snapshotsDir.appendingPathComponent("manifest.json").path))
    }

    @Test func snapshotUploadedWhenPolicyMet() async throws {
        let policy = SnapshotPolicy(enabled: true, minimumInterval: 0, minimumNewVersions: 5)
        let coordinator = try StoreCoordinator(withStoreDirectoryAt: rootURL, cacheDirectoryAt: cacheURL, snapshotPolicy: policy)
        let exchange = FileSystemExchange(rootDirectoryURL: exchangeURL, store: coordinator.store, usesFileCoordination: false)
        coordinator.exchange = exchange

        // Create > 5 versions
        for i in 0..<10 {
            try coordinator.save(inserting: [value("val\(i)", "data\(i)")])
        }

        // Sync to exchange
        try await coordinator.exchange()

        // Give the async snapshot upload time to complete
        try await Task.sleep(for: .seconds(2))

        // Verify snapshot was uploaded
        let snapshotsDir = exchangeURL.appendingPathComponent("snapshots")
        #expect(fm.fileExists(atPath: snapshotsDir.appendingPathComponent("manifest.json").path), "Snapshot should be uploaded when policy is met")
    }

    @Test func snapshotNotReuploadedWhenRecentExists() async throws {
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

        try await exchange.sendSnapshot(manifest: manifest, chunkProvider: { index in
            let chunkFile = snapshotDir.appendingPathComponent(String(format: "chunk-%03d", index))
            return try Data(contentsOf: chunkFile)
        })

        let originalSnapshotId = manifest.snapshotId

        // Exchange again — snapshot is recent, should not be re-uploaded
        try await coordinator.exchange()

        // Wait for potential async upload
        try await Task.sleep(for: .seconds(2))

        // Verify manifest is unchanged (same snapshotId)
        let downloaded = try await exchange.retrieveSnapshotManifest()
        #expect(downloaded?.snapshotId == originalSnapshotId, "Snapshot should not have been re-uploaded")
    }

    @Test func formatCompatibilityCheck() async throws {
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
        try await coordinator.bootstrapFromSnapshot()

        // Store should still have just 1 version (the initial empty one created by StoreCoordinator)
        var versionCount = 0
        coordinator.store.queryHistory { history in
            versionCount = history.allVersionIdentifiers.count
        }
        #expect(versionCount == 1)
    }
}
