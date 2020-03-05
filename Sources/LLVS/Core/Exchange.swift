//
//  Exchange.swift
//  LLVS
//
//  Created by Drew McCormack on 25/02/2019.
//

import Foundation
import Combine

enum ExchangeError: Swift.Error {
    case remoteVersionsWithUnknownPredecessors
    case missingVersion
    case unknown(error: Swift.Error)
}

public typealias VersionChanges = (version: Version, valueChanges: [Value.Change])

public protocol Exchange: class {

    @available(macOS 10.15, iOS 13, watchOS 6, *)
    var newVersionsAvailable: AnyPublisher<Void, Never> { get }
    var store: Store { get }
    
    var restorationState: Data? { get set }
    
    func retrieve(executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.ID]>)
    func prepareToRetrieve(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>)
    func retrieveAllVersionIdentifiers(executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.ID]>)
    func retrieveVersions(identifiedBy versionIds: [Version.ID], executingUponCompletion completionHandler: @escaping CompletionHandler<[Version]>)
    func retrieveValueChanges(forVersionsIdentifiedBy versionIds: [Version.ID], executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.ID:[Value.Change]]>)

    func send(executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.ID]>)
    func prepareToSend(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>)
    func send(versionChanges: [VersionChanges], executingUponCompletion completionHandler: @escaping CompletionHandler<Void>)
}

// MARK:- Retrieving

public extension Exchange {
    
    func retrieve(executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.ID]>) {
        log.trace("Retrieving")
        
        let prepare = AsynchronousTask { finish in
            self.prepareToRetrieve { result in
                finish(result)
            }
        }
        
        var remoteIds: [Version.ID]!
        let retrieveIds = AsynchronousTask { finish in
            self.retrieveAllVersionIdentifiers { result in
                remoteIds = result.value
                finish(result.voidResult)
            }
        }
        
        var remoteVersions: [Version]!
        let retrieveVersions = AsynchronousTask { finish in
            let toRetrieveIds = self.versionIdsMissingFromHistory(forRemoteIdentifiers: remoteIds)
            log.verbose("Version identifiers to retrieve: \(toRetrieveIds.idStrings)")
            self.retrieveVersions(identifiedBy: toRetrieveIds) { result in
                remoteVersions = result.value
                finish(result.voidResult)
            }
        }
        
        let addToHistory = AsynchronousTask { finish in
            log.verbose("Adding to history versions: \(remoteVersions.idStrings)")
            self.addToHistory(remoteVersions) { result in
                finish(result.voidResult)
            }
        }
                    
        [prepare, retrieveIds, retrieveVersions, addToHistory].executeInOrder { result in
            switch result {
            case .failure(let error):
                log.error("Failed to retrieve: \(error)")
                completionHandler(.failure(error))
            case .success:
                log.trace("Retrieved")
                completionHandler(.success(remoteIds!))
            }
        }
    }
    
    private func versionIdsMissingFromHistory(forRemoteIdentifiers remoteIdentifiers: [Version.ID]) -> [Version.ID] {
        var toRetrieveIds: [Version.ID]!
        self.store.queryHistory { history in
            let storeVersionIds = Set(history.allVersionIdentifiers)
            let remoteVersionIds = Set(remoteIdentifiers)
            toRetrieveIds = Array(remoteVersionIds.subtracting(storeVersionIds))
        }
        return toRetrieveIds
    }
    
    private func addToHistory(_ versions: [Version], executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        let versionsByIdentifier = versions.reduce(into: [:]) { result, version in
            result[version.id] = version
        }
        
        var remainingVersions = versions.sorted { $0.timestamp < $1.timestamp }
        var previousRemainingCount = -1
        let totalCount = remainingVersions.count
        var batchCount: Int = 0
        var currentBatchSize: Int = -1
        
        func determineNextBatchSize() -> Int {
            let batchDataSizeLimit = 5000000 // 5MB
            var dataSizeCount: Int64 = 0
            var versionIndex = 0
            while dataSizeCount <= batchDataSizeLimit, versionIndex < remainingVersions.count {
                let version = remainingVersions[versionIndex]
                dataSizeCount += version.valueDataSize ?? 100000 // Default to 100KB if we don't know size
                versionIndex += 1
            }
            
            // Note that the count is 1 more than index, and we already added one in loop.
            // So versionIndex is count at this point.
            var newBatchSize = versionIndex
            
            // If the previous
            if previousRemainingCount == remainingVersions.count {
                // Last batch size did not add any versions. Increase batch size
                // to see if that breaks the impasse.
                newBatchSize = max(newBatchSize, currentBatchSize+1)
            }

            return newBatchSize
        }

        // Setup a type of asynchronous while loop, that processes each dynamically formed batch
        // one at a time.
        func retrieveNextBatch() {
            guard !remainingVersions.isEmpty else {
                completionHandler(.success(()))
                return
            }
            guard batchCount <= 2*totalCount else {
                // Check that the batchCount is not bigger than twice the original length.
                // We allow for a failure at each batch size, which explains the factor 2
                completionHandler(.failure(ExchangeError.remoteVersionsWithUnknownPredecessors))
                return
            }
            
            batchCount += 1
            currentBatchSize = determineNextBatchSize()
            previousRemainingCount = remainingVersions.count

            let batchVersions = remainingVersions[0..<currentBatchSize]
            retrieveValueChanges(forVersionsIdentifiedBy: batchVersions.ids) { result in
                switch result {
                case let .failure(error):
                    log.error("Failed adding to history: \(error)")
                    completionHandler(.failure(error))
                case let .success(valueChangesByVersionIdentifier):
                    let valueChangesByVersion: [Version:[Value.Change]] = valueChangesByVersionIdentifier.reduce(into: [:]) { result, keyValue in
                        let version = versionsByIdentifier[keyValue.key]!
                        result[version] = keyValue.value
                    }
                    self.addToHistory(valueChangesByVersion: valueChangesByVersion) { result in
                        switch result {
                        case .success:
                            remainingVersions.removeFirst(currentBatchSize)
                            DispatchQueue.global(qos: .userInitiated).async { retrieveNextBatch() }
                        case .failure(let error):
                            if let exchangeError = error as? ExchangeError, case .remoteVersionsWithUnknownPredecessors = exchangeError {
                                // Maybe we just need a bigger batch size, so try again
                                DispatchQueue.global(qos: .userInitiated).async { retrieveNextBatch() }
                            } else {
                                completionHandler(.failure(error))
                            }
                        }
                    }
                }
            }
        }
        
        // Call the function for first time. It then recursive calls itself for other iterations
        retrieveNextBatch()
    }
    
    private func addToHistory(valueChangesByVersion: [Version:[Value.Change]], executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        let versions = Array(valueChangesByVersion.keys).sorted { $0.timestamp < $1.timestamp }
        if versions.isEmpty {
            log.trace("No versions. Finished adding to history")
            completionHandler(.success(()))
        } else if var version = appendableVersion(from: versions) {
            let valueChanges = valueChangesByVersion[version]!
            log.trace("Adding version to store: \(version.id.rawValue)")
            log.verbose("Value changes for \(version.id.rawValue): \(valueChanges)")
            
            do {
                if version.valueDataSize == nil {
                    version.valueDataSize = valueChanges.valueDataSize
                }
                try self.store.addVersion(version, storing: valueChanges)
            } catch Store.Error.attemptToAddExistingVersion {
                log.error("Failed adding to history because version already exists. Ignoring error")
            } catch {
                log.error("Failed adding to history: \(error)")
                completionHandler(.failure(error))
                return
            }
            
            var reducedVersions = valueChangesByVersion
            reducedVersions[version] = nil
            
            // Dispatch so that we don't end up with a huge recursive call stack
            DispatchQueue.global(qos: .userInitiated).async {
                self.addToHistory(valueChangesByVersion: reducedVersions, executingUponCompletion: completionHandler)
            }
        } else {
            log.error("Failed to add to history due to missing predecessors")
            completionHandler(.failure(ExchangeError.remoteVersionsWithUnknownPredecessors))
        }
    }
    
    private func appendableVersion(from versions: [Version]) -> Version? {
        return versions.first { v in
            return store.historyIncludesVersions(identifiedBy: v.predecessors?.ids ?? [])
        }
    }
    
}

// MARK:- Sending

public extension Exchange {
    
    func send(executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.ID]>) {
        let prepare = AsynchronousTask { finish in
            self.prepareToSend { result in
                finish(result)
            }
        }
        
        var remoteIds: [Version.ID]!
        let retrieveIds = AsynchronousTask { finish in
            self.retrieveAllVersionIdentifiers { result in
                remoteIds = result.value
                finish(result.voidResult)
            }
        }
        
        var toSendIds: [Version.ID]!
        let sendVersions = AsynchronousTask { finish in
            toSendIds = self.versionIdsMissingRemotely(forRemoteIdentifiers: remoteIds)
            do {
                let versionChanges: [VersionChanges] = try toSendIds!.map { versionId in
                    guard let version = try self.store.version(identifiedBy: versionId) else {
                        throw ExchangeError.missingVersion
                    }
                    let changes = try self.store.valueChanges(madeInVersionIdentifiedBy: versionId)
                    return (version, changes)
                }
                
                guard !versionChanges.isEmpty else {
                    finish(.success(()))
                    return
                }
                
                self.send(versionChanges: versionChanges) { result in
                    finish(result)
                }
            } catch {
                finish(.failure(error))
            }
        }

        [prepare, retrieveIds, sendVersions].executeInOrder { result in
            switch result {
            case .failure(let error):
                completionHandler(.failure(error))
            case .success:
                completionHandler(.success(toSendIds))
            }
        }
    }
    
    private func versionIdsMissingRemotely(forRemoteIdentifiers remoteIdentifiers: [Version.ID]) -> [Version.ID] {
        var toSendIds: [Version.ID]!
        self.store.queryHistory { history in
            let storeVersionIds = Set(history.allVersionIdentifiers)
            let remoteVersionIds = Set(remoteIdentifiers)
            toSendIds = Array(storeVersionIds.subtracting(remoteVersionIds))
        }
        return toSendIds
    }
}
