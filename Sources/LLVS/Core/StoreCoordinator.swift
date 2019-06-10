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
@available (macOS 10.14, iOS 13, *)
public class StoreCoordinator {
    
    public enum Error: Swift.Error {
    }
    
    private struct CachedData: Codable {
        var exchangeRestorationData: Data?
        var currentVersionIdentifier: Version.Identifier
    }
    
    public let store: Store
    public let exchange: Exchange?
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
    /// use `init(withStoreDirectoryAt:,cacheDirectoryAt:,exchange:)` instead.
    public convenience init(with exchange: Exchange? = nil) throws {
        try self.init(withStoreDirectoryAt: Self.defaultStoreDirectory, cacheDirectoryAt: Self.defaultStoreDirectory, exchange: exchange)
    }
    
    /// Gives full control over where the store is (directory location), and where cached data should be kept (directory).
    /// The directories will be created if they do not exist.
    public init(withStoreDirectoryAt storeURL: URL, cacheDirectoryAt coordinatorCacheURL: URL, exchange: Exchange? = nil) throws {
        self.storeDirectoryURL = storeURL
        self.cacheDirectoryURL = coordinatorCacheURL
        self.cachedCoordinatorFileURL = cacheDirectoryURL.appendingPathComponent("Coordinator.json")
        
        try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createDirectory(at: coordinatorCacheURL, withIntermediateDirectories: true, attributes: nil)

        self.store = try Store(rootDirectoryURL: storeURL)
        self.exchange = exchange
        
        // Load state from cache
        let fileManager = FileManager()
        let cachedData: CachedData
        if fileManager.fileExists(atPath: self.cachedCoordinatorFileURL.path),
            let data = try? Data(contentsOf: self.cachedCoordinatorFileURL),
            let cached = try? JSONDecoder().decode(CachedData.self, from: data) {
            cachedData = cached
        } else {
            let version: Version.Identifier
            if let head = store.mostRecentHead {
                version = head.identifier
            } else {
                version = try store.addVersion(basedOnPredecessor: nil, storing: []).identifier
            }
            cachedData = CachedData(currentVersionIdentifier: version)
        }
        
        // Set properties from cache
        self.currentVersion = cachedData.currentVersionIdentifier
        self.exchange?.restorationState = cachedData.exchangeRestorationData
        persist()
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
    public func save(changes: [Value.Change]) throws {
        currentVersion = try store.addVersion(basedOnPredecessor: currentVersion, storing: changes).identifier
    }
    
    
    // MARK: Sync
    
    public var isSyncing = false
    
    private lazy var syncQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    
    /// Completion is on the main thread.
    func sync(executingUponCompletion completionHandler: ((Swift.Error?) -> Void)? = nil) {
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
