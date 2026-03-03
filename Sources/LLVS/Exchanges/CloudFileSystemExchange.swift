//
//  CloudFileSystemExchange.swift
//  LLVS
//
//  Created by Drew McCormack on 03/03/2026.
//

import Foundation

/// An exchange that stores version and change data in a cloud file system.
///
/// Implements `Exchange` and `SnapshotExchange` by delegating all I/O to a `CloudFileSystem`.
/// The on-disk layout mirrors `FileSystemExchange`:
///
/// ```
/// {basePath}/
///   versions/{versionId}       -- JSON: {"version": Version}
///   changes/{versionId}        -- JSON: [Value.Change]
///   snapshots/manifest.json    -- JSON: SnapshotManifest
///   snapshots/chunk-000...     -- Binary chunk data
/// ```
public final class CloudFileSystemExchange: Exchange, SnapshotExchange, @unchecked Sendable {

    public enum Error: Swift.Error {
        case versionFileInvalid
        case changesFileInvalid
        case snapshotChunkMissing(Int)
    }

    public let store: Store
    public let cloudFileSystem: CloudFileSystem

    /// A path prefix allowing multiple stores per cloud account.
    public let basePath: String

    public let newVersionsAvailable: AsyncStream<Void>
    private let newVersionsContinuation: AsyncStream<Void>.Continuation

    public var restorationState: Data? {
        get { return nil }
        set {}
    }

    private var versionsPath: String { basePath + "/versions" }
    private var changesPath: String { basePath + "/changes" }
    private var snapshotsPath: String { basePath + "/snapshots" }

    /// Creates a cloud file system exchange.
    /// - Parameters:
    ///   - cloudFileSystem: The cloud file system to use for I/O.
    ///   - store: The local LLVS store.
    ///   - basePath: A path prefix for all cloud files (default: empty string).
    public init(cloudFileSystem: CloudFileSystem, store: Store, basePath: String = "") {
        self.cloudFileSystem = cloudFileSystem
        self.store = store
        self.basePath = basePath
        (self.newVersionsAvailable, self.newVersionsContinuation) = AsyncStream<Void>.makeStream()
    }

    deinit {
        newVersionsContinuation.finish()
    }

    // MARK: - Exchange

    public func prepareToRetrieve() async throws {
    }

    public func retrieveAllVersionIdentifiers() async throws -> [Version.ID] {
        do {
            let names = try await cloudFileSystem.contentsOfDirectory(at: versionsPath)
            return names.map { Version.ID($0) }
        } catch let error as CloudFileSystemError where error.isNotFound {
            return []
        }
    }

    public func retrieveVersions(identifiedBy versionIds: [Version.ID]) async throws -> [Version] {
        try await versionIds.asyncMap { versionId in
            let path = self.versionsPath + "/\(versionId.rawValue)"
            let data = try await self.cloudFileSystem.download(from: path)
            if let version = try JSONDecoder().decode([String: Version].self, from: data)["version"] {
                return version
            } else {
                throw Error.versionFileInvalid
            }
        }
    }

    public func retrieveValueChanges(forVersionsIdentifiedBy versionIds: [Version.ID]) async throws -> [Version.ID: [Value.Change]] {
        var result: [Version.ID: [Value.Change]] = [:]
        for versionId in versionIds {
            let path = changesPath + "/\(versionId.rawValue)"
            let data = try await cloudFileSystem.download(from: path)
            let changes = try JSONDecoder().decode([Value.Change].self, from: data)
            result[versionId] = changes
        }
        return result
    }

    public func prepareToSend() async throws {
    }

    public func send(versionChanges: [VersionChanges]) async throws {
        for (version, valueChanges) in versionChanges {
            // Upload changes before version file for consistency
            let changesData = try JSONEncoder().encode(valueChanges)
            try await cloudFileSystem.upload(data: changesData, to: changesPath + "/\(version.id.rawValue)")

            let versionData = try JSONEncoder().encode(["version": version])
            try await cloudFileSystem.upload(data: versionData, to: versionsPath + "/\(version.id.rawValue)")
        }
    }

    // MARK: - Snapshot Exchange

    public func retrieveSnapshotManifest() async throws -> SnapshotManifest? {
        let manifestPath = snapshotsPath + "/manifest.json"
        do {
            let exists = try await cloudFileSystem.fileExists(at: manifestPath)
            guard exists else { return nil }
            let data = try await cloudFileSystem.download(from: manifestPath)
            return try JSONDecoder().decode(SnapshotManifest.self, from: data)
        } catch let error as CloudFileSystemError where error.isNotFound {
            return nil
        }
    }

    public func retrieveSnapshotChunk(index: Int) async throws -> Data {
        let chunkPath = snapshotsPath + "/" + String(format: "chunk-%03d", index)
        do {
            return try await cloudFileSystem.download(from: chunkPath)
        } catch {
            throw Error.snapshotChunkMissing(index)
        }
    }

    public func sendSnapshot(manifest: SnapshotManifest, chunkProvider: @escaping @Sendable (Int) throws -> Data) async throws {
        // Remove previous snapshot if any
        try? await cloudFileSystem.removeDirectory(at: snapshotsPath)

        // Write chunks first
        for i in 0..<manifest.chunkCount {
            let chunkData = try chunkProvider(i)
            let chunkPath = snapshotsPath + "/" + String(format: "chunk-%03d", i)
            try await cloudFileSystem.upload(data: chunkData, to: chunkPath)
        }

        // Write manifest last
        let manifestData = try JSONEncoder().encode(manifest)
        try await cloudFileSystem.upload(data: manifestData, to: snapshotsPath + "/manifest.json")
    }
}

// MARK: - Async Helpers

private extension Array {
    func asyncMap<T>(_ transform: @escaping (Element) async throws -> T) async throws -> [T] {
        var results: [T] = []
        results.reserveCapacity(count)
        for element in self {
            try await results.append(transform(element))
        }
        return results
    }
}

// MARK: - CloudFileSystemError Helpers

extension CloudFileSystemError {
    var isNotFound: Bool {
        if case .fileNotFound = self { return true }
        if case .directoryListingFailed = self { return true }
        return false
    }
}
