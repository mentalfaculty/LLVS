//
//  CloudFileSystemExchangeTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 03/03/2026.
//

import XCTest
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

class CloudFileSystemExchangeTests: XCTestCase {

    var store1, store2: Store!
    var rootURL1, rootURL2: URL!
    var mockFS: MockCloudFileSystem!
    var exchange1, exchange2: CloudFileSystemExchange!

    override func setUp() {
        super.setUp()
        rootURL1 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        rootURL2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store1 = try! Store(rootDirectoryURL: rootURL1)
        store2 = try! Store(rootDirectoryURL: rootURL2)
        mockFS = MockCloudFileSystem()
        exchange1 = CloudFileSystemExchange(cloudFileSystem: mockFS, store: store1)
        exchange2 = CloudFileSystemExchange(cloudFileSystem: mockFS, store: store2)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: rootURL1)
        try? FileManager.default.removeItem(at: rootURL2)
        super.tearDown()
    }

    private func value(_ identifier: String, stringData: String) -> Value {
        Value(id: .init(identifier), data: stringData.data(using: .utf8)!)
    }

    // MARK: - Exchange Tests

    func testSendFiles() async throws {
        let val = value("CDEFGH", stringData: "Origin")
        let ver = try store1.makeVersion(basedOnPredecessor: nil, storing: [.insert(val)])

        // Nothing in the cloud yet
        let pathsBefore = mockFS.storedPaths
        XCTAssertTrue(pathsBefore.isEmpty)

        let versionIds = try await exchange1.send()
        XCTAssert(versionIds.contains(ver.id))

        // Verify files were uploaded
        let pathsAfter = mockFS.storedPaths
        XCTAssertTrue(pathsAfter.contains { $0.contains("versions/\(ver.id.rawValue)") })
        XCTAssertTrue(pathsAfter.contains { $0.contains("changes/\(ver.id.rawValue)") })
    }

    func testReceiveFiles() async throws {
        let val = value("CDEFGH", stringData: "Origin")
        let ver = try store1.makeVersion(basedOnPredecessor: nil, storing: [.insert(val)])

        let _ = try await exchange1.send()
        let versionIds = try await exchange2.retrieve()

        XCTAssert(versionIds.contains(ver.id))
        XCTAssertEqual(ver, try store2.version(identifiedBy: ver.id))
        XCTAssertNotNil(try store2.value(id: val.id, at: ver.id))
    }

    func testConcurrentChanges() async throws {
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

        versions1.forEach { XCTAssertNotNil(try! store2.version(identifiedBy: $0.id)) }
        versions2.forEach { XCTAssertNotNil(try! store1.version(identifiedBy: $0.id)) }

        for (ver, val) in zip(versions1, values1) {
            let val2 = try store2.value(id: val.id, storedAt: ver.id)!
            XCTAssertEqual(val.data, val2.data)
        }
        for (ver, val) in zip(versions2, values2) {
            let val1 = try store1.value(id: val.id, storedAt: ver.id)!
            XCTAssertEqual(val.data, val1.data)
        }

        let merge = try store1.mergeRelated(version: versions1.last!.id, with: versions2.last!.id, resolvingWith: MostRecentBranchFavoringArbiter())
        let _ = try await exchange1.send()
        let _ = try await exchange2.retrieve()
        XCTAssertNotNil(try store2.version(identifiedBy: merge.id))
        for val in values1 + values2 {
            let val2 = try store2.value(id: val.id, at: merge.id)!
            XCTAssertEqual(val.data, val2.data)
        }
    }

    func testSnapshotRoundTrip() async throws {
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
        let retrieved = try await exchange2.retrieveSnapshotManifest()
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.chunkCount, 3)
        XCTAssertEqual(retrieved?.latestVersionId, manifest.latestVersionId)

        // Retrieve chunks
        for i in 0..<3 {
            let chunkData = try await exchange2.retrieveSnapshotChunk(index: i)
            XCTAssertEqual(chunkData, chunks[i])
        }
    }

    func testBasePathIsolation() async throws {
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
        XCTAssertFalse(pathsA.isEmpty)
        XCTAssertFalse(pathsB.isEmpty)

        // Verify no overlap
        let overlapPaths = Set(pathsA).intersection(Set(pathsB))
        XCTAssertTrue(overlapPaths.isEmpty)

        // Store2 should not see storeA's versions via exchangeB
        let idsFromB = try await exchangeB.retrieveAllVersionIdentifiers()
        XCTAssertEqual(idsFromB.count, 1) // Only storeB's version
    }
}
