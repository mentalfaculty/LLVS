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
@available (macOS 10.15, iOS 13, *)
public class StoreCoordinator {
    
    private struct CachedData: Codable {
        var exchangeRestorationData: Data?
        var currentVersionIdentifier: Version.Identifier
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
    
    public var currentVersionPublisher = PassthroughSubject<Version.Identifier, Never>()
    
    public private(set) var currentVersion: Version.Identifier {
        didSet {
            guard self.currentVersion != oldValue else { return }
            persist()
            currentVersionPublisher.send(self.currentVersion)
        }
    }
    
    private class var defaultStoreDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let rootDir = appSupport.appendingPathComponent("LLVS/DefaultStore")
        return rootDir
    }
    
    private class var defaultCacheDirectory: URL {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let rootDir = cachesDir.appendingPathComponent("LLVS/CoordinatorCache")
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
        self.currentVersion = Version.Identifier() // Set a temporary version. Final is in cache
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
            let version: Version.Identifier
            if let head = store.mostRecentHead {
                version = head.identifier
            } else {
                version = try store.addVersion(basedOnPredecessor: nil, storing: []).identifier
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
    /// coordinator can track versions.
    public func save(_ changes: [Value.Change]) throws {
        currentVersion = try store.addVersion(basedOnPredecessor: currentVersion, storing: changes).identifier
    }
    
    
    // MARK: Fetching
    
    public func valueReferences() throws -> [Value.Reference] {
        var refs: [Value.Reference] = []
        try store.enumerate(version: currentVersion) { ref in
            refs.append(ref)
        }
        return refs
    }
    
    public func values() throws -> [Value] {
        return try valueReferences().map { try store.value(at: $0)! }
    }
    
    
    // MARK: Sync
    
    public var isSyncing = false
    
    private lazy var syncQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    
    /// Completion is on the main thread.
    public func sync(executingUponCompletion completionHandler: ((Swift.Error?) -> Void)? = nil) {
        syncQueue.addOperation {
            self.performSyncOnQueue(executingUponCompletion: completionHandler)
        }
    }
    
    private func performSyncOnQueue(executingUponCompletion completionHandler: ((Swift.Error?) -> Void)? = nil) {
        isSyncing = true

        guard let exchange = exchange else {
            OperationQueue.main.addOperation {
                let newVersion = self.store.mergeHeads(into: self.currentVersion, resolvingWith: self.mergeArbiter)
                if let newVersion = newVersion {
                    self.currentVersion = newVersion
                }
                completionHandler?(nil)
                self.isSyncing = false
            }
            return
        }
        
        let retrieve = AsynchronousTask { finish in
            exchange.retrieve { result in
                switch result {
                case let .failure(error):
                    finish(.failure(error))
                case .success:
                    finish(.success)
                }
            }
        }
        
        let send = AsynchronousTask { finish in
            exchange.send { result in
                switch result {
                case let .failure(error):
                    finish(.failure(error))
                case .success:
                    finish(.success)
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
            let newVersion = self.store.mergeHeads(into: self.currentVersion, resolvingWith: self.mergeArbiter)
            DispatchQueue.main.async {
                if let newVersion = newVersion {
                    self.currentVersion = newVersion
                }
                completionHandler?(returnError)
                self.isSyncing = false
            }
        }
    }
    
}
