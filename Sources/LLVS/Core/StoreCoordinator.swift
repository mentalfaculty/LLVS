//
//  StoreCoordinator.swift
//  LLVS
//
//  Created by Drew McCormack on 09/06/2019.
//  Copyright © 2019 Momenta B.V. All rights reserved.
//

import Foundation
import Synchronization

/// A `StoreCoordinator` takes care of all aspects of setting up a syncing store.
/// It's the simplest way to get started, though you may want more control for advanced use cases.
///
/// Thread-safety: `currentVersion` is protected by a `Mutex`. Other mutable properties
/// (`exchange`, `mergeArbiter`, `defaultMetadataForNewVersions`, `isExchanging`) are
/// set during initialization or within the serialized exchange flow.
public class StoreCoordinator: @unchecked Sendable {

    private struct CachedData: Codable {
        var exchangeRestorationData: Data?
        var currentVersionIdentifier: Version.ID
    }

    public let store: Store
    public let snapshotPolicy: SnapshotPolicy
    public var exchange: (any Exchange)? {
        didSet {
            exchange?.restorationState = cachedData?.exchangeRestorationData
        }
    }
    public var mergeArbiter: MergeArbiter = MostRecentChangeFavoringArbiter()

    public var defaultMetadataForNewVersions: Version.Metadata = [:]

    public let storeDirectoryURL: URL
    public let cacheDirectoryURL: URL

    private var cachedCoordinatorFileURL: URL

    public var exchangeRestorationData: Data? {
        return exchange?.restorationState
    }

    public private(set) var currentVersionUpdates: AsyncStream<Version.ID>
    private var currentVersionContinuation: AsyncStream<Version.ID>.Continuation?

    private let _currentVersion: Mutex<Version.ID>

    public var currentVersion: Version.ID {
        _currentVersion.withLock { $0 }
    }

    private func updateCurrentVersion(_ newValue: Version.ID) {
        let changed = _currentVersion.withLock { current -> Bool in
            guard current != newValue else { return false }
            current = newValue
            return true
        }
        if changed {
            persist()
            currentVersionContinuation?.yield(newValue)
        }
    }

    private class var defaultStoreDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let rootDir = appSupport.appendingPathComponent("LLVS").appendingPathComponent("DefaultStore")
        return rootDir
    }

    private class var defaultCacheDirectory: URL {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let rootDir = cachesDir.appendingPathComponent("LLVS").appendingPathComponent("CoordinatorCache")
        return rootDir
    }

    /// This will setup a store in the default location (Applicaton Support). If you need more than one store,
    /// use `init(withStoreDirectoryAt:,cacheDirectoryAt:)` instead.
    public convenience init(snapshotPolicy: SnapshotPolicy = .disabled) throws {
        try self.init(withStoreDirectoryAt: Self.defaultStoreDirectory, cacheDirectoryAt: Self.defaultStoreDirectory, snapshotPolicy: snapshotPolicy)
    }

    /// Gives full control over where the store is (directory location), and where cached data should be kept (directory).
    /// The directories will be created if they do not exist.
    public init(withStoreDirectoryAt storeURL: URL, cacheDirectoryAt coordinatorCacheURL: URL, snapshotPolicy: SnapshotPolicy = .disabled) throws {
        self.snapshotPolicy = snapshotPolicy
        self.storeDirectoryURL = storeURL
        self.cacheDirectoryURL = coordinatorCacheURL
        self.cachedCoordinatorFileURL = cacheDirectoryURL.appendingPathComponent("Coordinator.json")

        try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createDirectory(at: coordinatorCacheURL, withIntermediateDirectories: true, attributes: nil)

        self.store = try Store(rootDirectoryURL: storeURL)
        self._currentVersion = Mutex(Version.ID()) // Set a temporary version. Final is in cache

        var continuation: AsyncStream<Version.ID>.Continuation?
        self.currentVersionUpdates = AsyncStream { continuation = $0 }
        self.currentVersionContinuation = continuation

        try loadCache()
    }

    private func loadCache() throws {
        // Load state from cache
        let cachedData: CachedData
        var shouldPersist = false
        if let cached = self.cachedData {
            cachedData = cached
        } else {
            // Get most recent, or make first commit
            let version: Version.ID
            if let head = store.mostRecentHead {
                version = head.id
            } else {
                version = try store.makeVersion(basedOnPredecessor: nil, storing: []).id
            }
            cachedData = CachedData(currentVersionIdentifier: version)
            shouldPersist = true
        }

        // Set properties from cache
        updateCurrentVersion(cachedData.currentVersionIdentifier)
        if shouldPersist { persist() }
    }

    private var cachedData: CachedData? {
        let fileManager = FileManager()
        if fileManager.fileExists(atPath: self.cachedCoordinatorFileURL.path),
            let data = try? Data(contentsOf: self.cachedCoordinatorFileURL),
            let cached = try? JSONDecoder().decode(CachedData.self, from: data) {
            return cached
        } else {
            return nil
        }
    }

    /// Store cached data
    private func persist() {
        let cachedData = CachedData(exchangeRestorationData: exchange?.restorationState, currentVersionIdentifier: currentVersion)
        if let data = try? JSONEncoder().encode(cachedData) {
            try? data.write(to: cachedCoordinatorFileURL)
        }
    }


    // MARK: Heads

    public func heads(withBranch branch: Branch) -> [Version.ID] {
        store.heads(withBranch: branch)
    }

    /// Will attempt to get the first branch version, if one exists; if not, will return the current version.
    /// This is just a convenient way to get a base version.
    public func versionForBranchOrCurrentHead(for branch: Branch? = nil) -> Version.ID {
        branch.flatMap({ heads(withBranch: $0).first }) ?? currentVersion
    }


    // MARK: Saving

    /// You should use this to save instead of using the store directly, so that the
    /// coordinator can track versions. Otherwise you will need to merge to see the changes.
    public func save(_ changes: [Value.Change], in branch: Branch? = nil, metadata: Version.Metadata? = nil) throws {
        guard !changes.isEmpty || metadata != nil else { return }
        var metadata = metadata ?? defaultMetadataForNewVersions
        if let branch = branch { metadata[.branch] = .init(branch.rawValue) }
        updateCurrentVersion(try store.makeVersion(basedOnPredecessor: versionForBranchOrCurrentHead(for: branch), storing: changes, metadata: metadata).id)
    }

    public func save(inserting inserts: [Value] = [], updating updates: [Value] = [], removing removals: [Value.ID] = [], in branch: Branch? = nil, metadata: Version.Metadata? = nil) throws {
        guard !inserts.isEmpty || !updates.isEmpty || !removals.isEmpty || metadata != nil else { return }
        var metadata = metadata ?? defaultMetadataForNewVersions
        if let branch = branch { metadata[.branch] = .init(branch.rawValue) }
        updateCurrentVersion(try store.makeVersion(basedOnPredecessor: versionForBranchOrCurrentHead(for: branch), inserting: inserts, updating: updates, removing: removals, metadata: metadata).id)
    }


    // MARK: Fetching

    /// Pass a specific version, or nil for the current version
    public func valueReferences(at version: Version.ID? = nil) throws -> [Value.Reference] {
        try store.valueReferences(at: version ?? currentVersion)
    }

    public func values(at version: Version.ID? = nil) throws -> [Value] {
        try autoreleasepool {
            return try valueReferences(at: version).map { try store.value(storedAt: $0)! }
        }
    }

    public func value(idString: String) throws -> Value? {
        return try store.value(idString: idString, at: currentVersion)
    }

    public func value(id: Value.ID) throws -> Value? {
        return try store.value(id: id, at: currentVersion)
    }

    public func value(idString: String, on branch: Branch?) throws -> Value? {
        return try store.value(idString: idString, at: versionForBranchOrCurrentHead(for: branch))
    }

    public func value(id: Value.ID, on branch: Branch?) throws -> Value? {
        return try store.value(id: id, at: versionForBranchOrCurrentHead(for: branch))
    }


    // MARK: Sync

    public private(set) var isExchanging = false

    /// Serializer to ensure one exchange at a time.
    private var exchangeSerializer = ExchangeSerializer()

    /// This transfers data between cloud and local store, but does not alter the current branch or do any merging.
    /// It's a bit like a two-way version of Git's fetch.
    public func exchange() async throws {
        try await exchangeSerializer.enqueue { [self] in
            try await self.performExchange()
        }
    }

    private func performExchange() async throws {
        isExchanging = true
        defer { isExchanging = false }

        guard let exchange = exchange else { return }

        let _ = try await exchange.retrieve()
        let _ = try await exchange.send()

        // Upload snapshot if policy allows (fire and forget)
        Task { [weak self] in
            try? await self?.uploadSnapshotIfNeeded()
        }
    }

    /// Merging any extra heads, or fast forward to latest. It's a good idea to save data just before calling this, so that
    /// in view edits are committed. Returns true if the merge changed the current version; false otherwise.
    /// Note that the default behavior is not to merge in named branches. These are usually used for background work, and need to be merged in under controlled circumstances.
    @discardableResult public func merge(metadata: Version.Metadata? = nil, headSelection: Store.MergeHeadSelection = .allExceptBranches) -> Bool {
        let metadata = metadata ?? defaultMetadataForNewVersions
        let newVersion = self.store.mergeHeads(into: self.currentVersion, resolvingWith: self.mergeArbiter, headSelection: headSelection, metadata: metadata)
        if let newVersion = newVersion {
            updateCurrentVersion(newVersion)
            return true
        } else {
            return false
        }
    }


    // MARK: Snapshots

    /// Download and restore a cloud snapshot if available and compatible.
    /// Call before the first exchange on a new device.
    public func bootstrapFromSnapshot() async throws {
        guard let snapshotExchange = exchange as? SnapshotExchange,
              let snapshotStorage = store.storage as? SnapshotCapable else {
            return
        }

        // Check store has minimal history (≤ 1 version) — skip if already populated
        var versionCount = 0
        store.queryHistory { history in
            versionCount = history.allVersionIdentifiers.count
        }
        guard versionCount <= 1 else { return }

        guard let manifest = try await snapshotExchange.retrieveSnapshotManifest() else { return }

        // Check format matches
        guard manifest.format == snapshotStorage.snapshotFormat else { return }

        // Download chunks to temp directory
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for i in 0..<manifest.chunkCount {
            let data = try await snapshotExchange.retrieveSnapshotChunk(index: i)
            let chunkFile = tempDir.appendingPathComponent(String(format: "chunk-%03d", i))
            try data.write(to: chunkFile)
        }

        try snapshotStorage.restoreFromSnapshotChunks(
            storeRootURL: self.store.rootDirectoryURL,
            from: tempDir,
            manifest: manifest
        )
        try self.store.reloadHistory()

        // Update currentVersion to the latest head
        if let head = self.store.mostRecentHead {
            updateCurrentVersion(head.id)
        }
    }

    internal func uploadSnapshotIfNeeded() async throws {
        guard snapshotPolicy.enabled,
              let snapshotExchange = exchange as? SnapshotExchange,
              let snapshotStorage = store.storage as? SnapshotCapable else {
            return
        }

        // Check current version count
        var currentVersionCount = 0
        store.queryHistory { history in
            currentVersionCount = history.allVersionIdentifiers.count
        }

        let existingManifest = try await snapshotExchange.retrieveSnapshotManifest()

        if let manifest = existingManifest {
            // Skip if recent enough
            if manifest.createdAt.timeIntervalSinceNow > -self.snapshotPolicy.minimumInterval {
                return
            }
            // Skip if not enough new versions
            if currentVersionCount - manifest.versionCount < self.snapshotPolicy.minimumNewVersions {
                return
            }
        }

        // Write snapshot to temp directory
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifest = try snapshotStorage.writeSnapshotChunks(
            storeRootURL: self.store.rootDirectoryURL,
            to: tempDir,
            maxChunkSize: 5_000_000
        )

        try await snapshotExchange.sendSnapshot(manifest: manifest, chunkProvider: { index in
            let chunkFile = tempDir.appendingPathComponent(String(format: "chunk-%03d", index))
            return try Data(contentsOf: chunkFile)
        })
    }
}


// MARK: - ExchangeSerializer

/// Ensures only one exchange runs at a time using an AsyncStream as a FIFO queue.
private final class ExchangeSerializer: @unchecked Sendable {
    private typealias Work = @Sendable () async throws -> Void
    private let stream: AsyncStream<Work>
    private let continuation: AsyncStream<Work>.Continuation

    init() {
        (stream, continuation) = AsyncStream<Work>.makeStream()
        Task { [stream] in
            for await work in stream {
                try? await work()
            }
        }
    }

    func enqueue(_ work: @escaping @Sendable () async throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            continuation.yield {
                do {
                    try await work()
                    done.resume()
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }
}
