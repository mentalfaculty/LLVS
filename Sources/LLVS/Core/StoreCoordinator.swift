//
//  StoreCoordinator.swift
//  LLVS
//
//  Created by Drew McCormack on 09/06/2019.
//  Copyright © 2019 Momenta B.V. All rights reserved.
//

import Foundation
import Combine

/// A `StoreCoordinator` takes care of all aspects of setting up a syncing store.
/// It's the simplest way to get started, though you may want more control for advanced use cases.
@available (macOS 10.14, iOS 11, watchOS 5, *)
public class StoreCoordinator {
    
    private struct CachedData: Codable {
        var exchangeRestorationData: Data?
        var currentVersionIdentifier: Version.ID
    }
    
    public let store: Store
    public var exchange: Exchange? {
        didSet {
            exchange?.restorationState = cachedData?.exchangeRestorationData
        }
    }
    public var mergeArbiter: MergeArbiter = MostRecentChangeFavoringArbiter()
    
    public let storeDirectoryURL: URL
    public let cacheDirectoryURL: URL
    
    private var cachedCoordinatorFileURL: URL
    
    public var exchangeRestorationData: Data? {
        return exchange?.restorationState
    }
    
    @available (macOS 10.15, iOS 13, watchOS 6, *)
    public lazy private(set) var currentVersionSubject: CurrentValueSubject<Version.ID, Never> = .init(.init())
    
    public private(set) var currentVersion: Version.ID {
        didSet {
            guard self.currentVersion != oldValue else { return }
            persist()
            if #available (macOS 10.15, iOS 13, watchOS 6, *) {
                currentVersionSubject.value = self.currentVersion
            }
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
    public convenience init() throws {
        try self.init(withStoreDirectoryAt: Self.defaultStoreDirectory, cacheDirectoryAt: Self.defaultStoreDirectory)
    }
    
    /// Gives full control over where the store is (directory location), and where cached data should be kept (directory).
    /// The directories will be created if they do not exist.
    public init(withStoreDirectoryAt storeURL: URL, cacheDirectoryAt coordinatorCacheURL: URL) throws {
        self.storeDirectoryURL = storeURL
        self.cacheDirectoryURL = coordinatorCacheURL
        self.cachedCoordinatorFileURL = cacheDirectoryURL.appendingPathComponent("Coordinator.json")
        
        try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createDirectory(at: coordinatorCacheURL, withIntermediateDirectories: true, attributes: nil)

        self.store = try Store(rootDirectoryURL: storeURL)
        self.currentVersion = Version.ID() // Set a temporary version. Final is in cache
        if #available (macOS 10.15, iOS 13, watchOS 6, *) {
            self.currentVersionSubject = .init(self.currentVersion)
        }
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
        self.currentVersion = cachedData.currentVersionIdentifier
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
    
    
    // MARK: Saving
    
    /// You should use this to save instead of using the store directly, so that the
    /// coordinator can track versions. Otherwise you will need to merge to see the changes.
    public func save(_ changes: [Value.Change]) throws {
        guard !changes.isEmpty else { return }
        currentVersion = try store.makeVersion(basedOnPredecessor: currentVersion, storing: changes).id
    }
    
    public func save(inserting inserts: [Value] = [], updating updates: [Value] = [], removing removals: [Value.ID] = []) throws {
        guard !inserts.isEmpty || !updates.isEmpty || !removals.isEmpty else { return }
        currentVersion = try store.makeVersion(basedOnPredecessor: currentVersion, inserting: inserts, updating: updates, removing: removals).id
    }
    
    
    // MARK: Fetching
    
    /// Pass a specific version, or nil for the current version
    public func valueReferences(at version: Version.ID? = nil) throws -> [Value.Reference] {
        var refs: [Value.Reference] = []
        try store.enumerate(version: version ?? currentVersion) { ref in
            refs.append(ref)
        }
        return refs
    }
    
    public func values(at version: Version.ID? = nil) throws -> [Value] {
        return try valueReferences(at: version).map { try store.value(storedAt: $0)! }
    }
    
    public func value(idString: String) throws -> Value? {
        return try store.value(idString: idString, at: currentVersion)
    }
    
    public func value(id: Value.ID) throws -> Value? {
        return try store.value(id: id, at: currentVersion)
    }
    
    
    // MARK: Sync
    
    public var isExchanging = false
    
    private lazy var exchangeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    
    /// This transfers data between cloud and local store, but does not alter the current branch or do any merging.
    /// It's a bit like a two-way version of Git's fetch. Completion is on the main thread.
    public func exchange(executingUponCompletion completionHandler: ((Swift.Error?) -> Void)? = nil) {
        exchangeQueue.addOperation {
            self.performExchangeOnQueue(executingUponCompletion: completionHandler)
        }
    }
    
    private func performExchangeOnQueue(executingUponCompletion completionHandler: ((Swift.Error?) -> Void)? = nil) {
        isExchanging = true

        guard let exchange = exchange else {
            OperationQueue.main.addOperation {
                completionHandler?(nil)
                self.isExchanging = false
            }
            return
        }
        
        let retrieve = AsynchronousTask { finish in
            exchange.retrieve { result in
                switch result {
                case let .failure(error):
                    finish(.failure(error))
                case .success:
                    finish(.success(()))
                }
            }
        }
        
        let send = AsynchronousTask { finish in
            exchange.send { result in
                switch result {
                case let .failure(error):
                    finish(.failure(error))
                case .success:
                    finish(.success(()))
                }
            }
        }
        
        [retrieve, send].executeInOrder { result in
            var returnError: Swift.Error?
            switch result {
            case let .failure(error):
                returnError = error
                log.error("Failed to sync: \(error)")
            case .success:
                log.trace("Sync successful")
            }
            OperationQueue.main.addOperation {
                completionHandler?(returnError)
                self.isExchanging = false
            }
        }
    }
    
    /// Merging any extra heads, or fast forward to latest. It's a good idea to save data just before calling this, so that
    /// in view edits are committed. Returns true if the merge changed the current version; false otherwise.
    @discardableResult public func merge() -> Bool {
        let newVersion = self.store.mergeHeads(into: self.currentVersion, resolvingWith: self.mergeArbiter)
        if let newVersion = newVersion {
            self.currentVersion = newVersion
            return true
        } else {
            return false
        }
    }
}
