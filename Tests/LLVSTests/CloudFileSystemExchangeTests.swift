//
//  CloudFileSystemExchangeTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 03/03/2026.
//

import Testing
import Foundation
@testable import LLVS

// MARK: - Mock Cloud File System

/// An in-memory implementation of `CloudFileSystem` for testing.
final class MockCloudFileSystem: CloudFileSystem, @unchecked Sendable {

    private var files: [String: Data] = [:]

    func fileExists(at path: String) async throws -> Bool {
        files[path] != nil
    }

    func contentsOfDirectory(at path: String) async throws -> [String] {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        var names: Set<String> = []
        for key in files.keys {
            if key.hasPrefix(prefix) {
                let remainder = String(key.dropFirst(prefix.count))
                // Only direct children (no further slashes)
                if !remainder.contains("/") {
                    names.insert(remainder)
                }
            }
        }
        return Array(names).sorted()
    }

    func upload(data: Data, to path: String) async throws {
        files[path] = data
    }

    func download(from path: String) async throws -> Data {
        guard let data = files[path] else {
            throw CloudFileSystemError.fileNotFound
        }
        return data
    }

    func remove(at path: String) async throws {
        files.removeValue(forKey: path)
    }

    func removeDirectory(at path: String) async throws {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        files = files.filter { !$0.key.hasPrefix(prefix) && $0.key != path }
    }

    /// Expose stored file paths for assertions.
    var storedPaths: [String] {
        Array(files.keys).sorted()
    }
}

// MARK: - Tests

@Suite class CloudFileSystemExchangeTests {

    let store1: Store
    let store2: Store
    let rootURL1: URL
    let rootURL2: URL
    let mockFS: MockCloudFileSystem
    let exchange1: CloudFileSystemExchange
    let exchange2: CloudFileSystemExchange

    init() throws {
        rootURL1 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        rootURL2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store1 = try Store(rootDirectoryURL: rootURL1)
        store2 = try Store(rootDirectoryURL: rootURL2)
        mockFS = MockCloudFileSystem()
        exchange1 = CloudFileSystemExchange(cloudFileSystem: mockFS, store: store1)
        exchange2 = CloudFileSystemExchange(cloudFileSystem: mockFS, store: store2)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL1)
        try? FileManager.default.removeItem(at: rootURL2)
    }

    private func value(_ identifier: String, stringData: String) -> Value {
        Value(id: .init(identifier), data: stringData.data(using: .utf8)!)
    }

    // MARK: - Exchange Tests

    @Test func sendFiles() async throws {
        let val = value("CDEFGH", stringData: "Origin")
        let ver = try store1.makeVersion(basedOnPredecessor: nil, storing: [.insert(val)])

        // Nothing in the cloud yet
        let pathsBefore = mockFS.storedPaths
        #expect(pathsBefore.isEmpty)

        let versionIds = try await exchange1.send()
        #expect(versionIds.contains(ver.id))

        // Verify files were uploaded
        let pathsAfter = mockFS.storedPaths
        #expect(pathsAfter.contains { $0.contains("versions/\(ver.id.rawValue)") })
        #expect(pathsAfter.contains { $0.contains("changes/\(ver.id.rawValue)") })
    }

    @Test func receiveFiles() async throws {
        let val = value("CDEFGH", stringData: "Origin")
        let ver = try store1.makeVersion(basedOnPredecessor: nil, storing: [.insert(val)])

        let _ = try await exchange1.send()
        let versionIds = try await exchange2.retrieve()

        #expect(versionIds.contains(ver.id))
        #expect(try ver == store2.version(identifiedBy: ver.id))
        #expect(try store2.value(id: val.id, at: ver.id) != nil)
    }

    @Test func concurrentChanges() async throws {
        let origin = try store1.makeVersion(basedOnPredecessor: nil, storing: [])
        let _ = try await exchange1.send()
        let _ = try await exchange2.retrieve()

        func add(numberOfVersions: Int, store: Store) -> ([Version], [Value]) {
            var versions: [Version] = []
            var values: [Value] = []
            for _ in 0..<numberOfVersions {
                let id = UUID().uuidString
                let val = value(id, stringData: id)
                let ver = try! store.makeVersion(basedOnPredecessor: versions.last?.id ?? origin.id, storing: [.insert(val)])
                versions.append(ver)
                values.append(val)
            }
            return (versions, values)
        }

        let (versions1, values1) = add(numberOfVersions: 3, store: store1)
        let (versions2, values2) = add(numberOfVersions: 3, store: store2)

        let _ = try await exchange1.send()
        let _ = try await exchange2.retrieve()
        let _ = try await exchange2.send()
        let _ = try await exchange1.retrieve()

        versions1.forEach { #expect(try! store2.version(identifiedBy: $0.id) != nil) }
        versions2.forEach { #expect(try! store1.version(identifiedBy: $0.id) != nil) }

        for (ver, val) in zip(versions1, values1) {
            let val2 = try store2.value(id: val.id, storedAt: ver.id)!
            #expect(val.data == val2.data)
        }
        for (ver, val) in zip(versions2, values2) {
            let val1 = try store1.value(id: val.id, storedAt: ver.id)!
            #expect(val.data == val1.data)
        }

        let merge = try store1.mergeRelated(version: versions1.last!.id, with: versions2.last!.id, resolvingWith: MostRecentBranchFavoringArbiter())
        let _ = try await exchange1.send()
        let _ = try await exchange2.retrieve()
        #expect(try store2.version(identifiedBy: merge.id) != nil)
        for val in values1 + values2 {
            let val2 = try store2.value(id: val.id, at: merge.id)!
            #expect(val.data == val2.data)
        }
    }

    @Test func snapshotRoundTrip() async throws {
        let manifest = SnapshotManifest(
            format: "test",
            latestVersionId: Version.ID(UUID().uuidString),
            versionCount: 5,
            chunkCount: 3,
            totalSize: 300
        )
        let chunks = (0..<3).map { "chunk-\($0)-data".data(using: .utf8)! }

        try await exchange1.sendSnapshot(manifest: manifest) { index in
            chunks[index]
        }

        // Retrieve manifest
        let retrieved = try #require(try await exchange2.retrieveSnapshotManifest())
        #expect(retrieved.chunkCount == 3)
        #expect(retrieved.latestVersionId == manifest.latestVersionId)

        // Retrieve chunks, addressed by the id the manifest carries, as a reader would
        for i in 0..<3 {
            let chunkData = try await exchange2.retrieveSnapshotChunk(snapshotId: retrieved.snapshotId, index: i)
            #expect(chunkData == chunks[i])
        }
    }

    @Test func basePathIsolation() async throws {
        let mockFS2 = MockCloudFileSystem()
        let exchangeA = CloudFileSystemExchange(cloudFileSystem: mockFS2, store: store1, basePath: "storeA")
        let exchangeB = CloudFileSystemExchange(cloudFileSystem: mockFS2, store: store2, basePath: "storeB")

        let valA = value("A", stringData: "DataA")
        let _ = try store1.makeVersion(basedOnPredecessor: nil, storing: [.insert(valA)])

        let valB = value("B", stringData: "DataB")
        let _ = try store2.makeVersion(basedOnPredecessor: nil, storing: [.insert(valB)])

        let _ = try await exchangeA.send()
        let _ = try await exchangeB.send()

        // Verify files are under different paths
        let pathsA = mockFS2.storedPaths.filter { $0.hasPrefix("storeA/") }
        let pathsB = mockFS2.storedPaths.filter { $0.hasPrefix("storeB/") }
        #expect(!pathsA.isEmpty)
        #expect(!pathsB.isEmpty)

        // Verify no overlap
        let overlapPaths = Set(pathsA).intersection(Set(pathsB))
        #expect(overlapPaths.isEmpty)

        // Store2 should not see storeA's versions via exchangeB
        let idsFromB = try await exchangeB.retrieveAllVersionIdentifiers()
        #expect(idsFromB.count == 1) // Only storeB's version
    }

    // MARK: - Snapshot Chunk Isolation

    private func manifest(chunkCount: Int, versionCount: Int = 5) -> SnapshotManifest {
        SnapshotManifest(
            format: "test",
            latestVersionId: Version.ID(UUID().uuidString),
            versionCount: versionCount,
            chunkCount: chunkCount,
            totalSize: Int64(chunkCount * 100)
        )
    }

    @Test func chunksAreStoredUnderTheirOwnSnapshotId() async throws {
        let manifest = manifest(chunkCount: 2)

        try await exchange1.sendSnapshot(manifest: manifest) { index in
            Data("chunk-\(index)".utf8)
        }

        // Every chunk sits inside a directory named for the snapshot, so a later snapshot
        // writing chunk-000 cannot land on this one's
        let chunkPaths = mockFS.storedPaths.filter { $0.contains("chunk-") }
        #expect(chunkPaths.count == 2)
        #expect(chunkPaths.allSatisfy { $0.contains("/\(manifest.snapshotId)/") },
                "chunk paths were: \(chunkPaths)")
    }

    @Test func aReaderInterruptedByANewSnapshotFailsRatherThanMixingChunks() async throws {
        // This is the bug. A reader fetched manifest A and is part-way through its chunks when a
        // second device uploads snapshot B. Before, B's chunks overwrote A's in place, so the
        // reader silently assembled halves of two different stores and restored the result.
        //
        // Now A's chunks live under A's id, so B cannot land on them. B's upload does delete them
        // once B's manifest is live — keeping every snapshot would grow without bound — so the
        // interrupted reader gets a missing chunk. That throws out of `bootstrapFromSnapshot`
        // before anything is written to the store, and the next attempt picks up B cleanly.
        // A loud failure that restores nothing beats a silent one that restores a mixture.
        let manifestA = manifest(chunkCount: 2)
        try await exchange1.sendSnapshot(manifest: manifestA) { index in
            Data("A-chunk-\(index)".utf8)
        }

        // The reader takes the manifest, and one chunk, before anything changes
        let readerManifest = try #require(try await exchange2.retrieveSnapshotManifest())
        let firstChunk = try await exchange2.retrieveSnapshotChunk(snapshotId: readerManifest.snapshotId, index: 0)
        #expect(String(data: firstChunk, encoding: .utf8) == "A-chunk-0")

        // Now a second snapshot lands and replaces the first
        let manifestB = manifest(chunkCount: 2)
        try await exchange1.sendSnapshot(manifest: manifestB) { index in
            Data("B-chunk-\(index)".utf8)
        }

        // The reader asks for A's second chunk. It must not be handed B's
        // Gone, rather than silently replaced by B's. Matching the specific case matters: a bare
        // `catch` would keep this test green if some unrelated failure started throwing here
        do {
            let chunk = try await exchange2.retrieveSnapshotChunk(snapshotId: readerManifest.snapshotId, index: 1)
            Issue.record("expected the chunk to be gone, got \(String(data: chunk, encoding: .utf8) ?? "?")")
        } catch let error as CloudFileSystemExchange.Error {
            guard case .snapshotChunkMissing(1) = error else {
                Issue.record("expected a missing chunk 1, got \(error)")
                return
            }
        }

        // And B's own chunks are intact and correct for a reader starting now
        let freshManifest = try #require(try await exchange2.retrieveSnapshotManifest())
        #expect(freshManifest.snapshotId == manifestB.snapshotId)
        let bChunk = try await exchange2.retrieveSnapshotChunk(snapshotId: freshManifest.snapshotId, index: 1)
        #expect(String(data: bChunk, encoding: .utf8) == "B-chunk-1")
    }

    @Test func theReplacedSnapshotsChunksAreCleanedUp() async throws {
        // Keeping every snapshot forever would grow without bound
        let manifestA = manifest(chunkCount: 2)
        try await exchange1.sendSnapshot(manifest: manifestA) { index in Data("A\(index)".utf8) }

        let manifestB = manifest(chunkCount: 2)
        try await exchange1.sendSnapshot(manifest: manifestB) { index in Data("B\(index)".utf8) }

        let remaining = mockFS.storedPaths.filter { $0.contains("chunk-") }
        #expect(remaining.allSatisfy { $0.contains("/\(manifestB.snapshotId)/") },
                "the old snapshot's chunks were left behind: \(remaining)")
        #expect(remaining.count == 2)
    }

    @Test func theManifestIsWrittenAfterTheChunks() async throws {
        // A reader that sees the new manifest must find its chunks already there. Uploading the
        // manifest first would point readers at chunks that had not arrived.
        let recordingFS = RecordingCloudFileSystem()
        let exchange = CloudFileSystemExchange(cloudFileSystem: recordingFS, store: store1)
        let manifest = manifest(chunkCount: 3)

        try await exchange.sendSnapshot(manifest: manifest) { index in Data("c\(index)".utf8) }

        let manifestIndex = try #require(recordingFS.uploadOrder.firstIndex { $0.hasSuffix("manifest.json") })
        let lastChunkIndex = try #require(recordingFS.uploadOrder.lastIndex { $0.contains("chunk-") })
        #expect(lastChunkIndex < manifestIndex, "upload order was: \(recordingFS.uploadOrder)")
    }

    @Test func theOldChunksGoOnlyAfterTheNewManifestIsWritten() async throws {
        // The dangerous ordering: deleting first leaves a reader with a manifest pointing at
        // chunks that are already gone
        let recordingFS = RecordingCloudFileSystem()
        let exchange = CloudFileSystemExchange(cloudFileSystem: recordingFS, store: store1)

        let manifestA = manifest(chunkCount: 1)
        try await exchange.sendSnapshot(manifest: manifestA) { _ in Data("A".utf8) }

        recordingFS.resetLog()

        let manifestB = manifest(chunkCount: 1)
        try await exchange.sendSnapshot(manifest: manifestB) { _ in Data("B".utf8) }

        // Uploads and deletes go into one log, so their positions are directly comparable
        let log = recordingFS.operationLog
        let manifestWrite = try #require(log.firstIndex {
            if case let .upload(path) = $0 { return path.hasSuffix("snapshots/manifest.json") }
            return false
        })
        let oldSnapshotRemoval = try #require(log.firstIndex {
            if case let .removeDirectory(path) = $0 { return path.contains(manifestA.snapshotId) }
            return false
        })

        #expect(oldSnapshotRemoval > manifestWrite,
                "the old snapshot was removed before the new manifest landed: \(log)")
    }

    @Test func aManifestWithAnUnsafeIdIsRefused() async throws {
        // The manifest comes from the remote, and its id becomes a path component. An id of
        // "../versions" would send the clean-up delete outside the snapshots directory.
        let hostile = SnapshotManifest(
            snapshotId: "../../versions",
            format: "test",
            latestVersionId: Version.ID(UUID().uuidString),
            versionCount: 1,
            chunkCount: 1,
            totalSize: 10
        )
        let data = try JSONEncoder().encode(hostile)
        try await mockFS.upload(data: data, to: exchange2.basePath + "/snapshots/manifest.json")

        await #expect(throws: CloudFileSystemExchange.Error.self) {
            _ = try await self.exchange2.retrieveSnapshotManifest()
        }
    }

    @Test func aPlainUUIDIdIsAccepted() async throws {
        // The guard must not reject the ids this library actually writes
        let manifest = manifest(chunkCount: 1)
        #expect(manifest.hasPathSafeId)

        try await exchange1.sendSnapshot(manifest: manifest) { _ in Data("x".utf8) }
        let retrieved = try await exchange2.retrieveSnapshotManifest()
        #expect(retrieved?.snapshotId == manifest.snapshotId)
    }
}

// MARK: - Recording Cloud File System

/// Records the order of writes and deletes, so a test can assert on their sequence.
final class RecordingCloudFileSystem: CloudFileSystem, @unchecked Sendable {

    enum Operation: Equatable {
        case upload(String)
        case removeDirectory(String)
    }

    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var log: [Operation] = []

    var operationLog: [Operation] { lock.withLock { log } }

    var uploadOrder: [String] {
        operationLog.compactMap { if case let .upload(path) = $0 { return path } else { return nil } }
    }

    func resetLog() { lock.withLock { log = [] } }

    func fileExists(at path: String) async throws -> Bool {
        lock.withLock { files[path] != nil }
    }

    func contentsOfDirectory(at path: String) async throws -> [String] {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return lock.withLock {
            var names: Set<String> = []
            for key in files.keys where key.hasPrefix(prefix) {
                let remainder = String(key.dropFirst(prefix.count))
                if !remainder.contains("/") { names.insert(remainder) }
            }
            return Array(names).sorted()
        }
    }

    func upload(data: Data, to path: String) async throws {
        lock.withLock {
            files[path] = data
            log.append(.upload(path))
        }
    }

    func download(from path: String) async throws -> Data {
        try lock.withLock {
            guard let data = files[path] else { throw CloudFileSystemError.fileNotFound }
            return data
        }
    }

    func remove(at path: String) async throws {
        lock.withLock { files.removeValue(forKey: path) }
    }

    func removeDirectory(at path: String) async throws {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        lock.withLock {
            files = files.filter { !$0.key.hasPrefix(prefix) && $0.key != path }
            log.append(.removeDirectory(path))
        }
    }
}
