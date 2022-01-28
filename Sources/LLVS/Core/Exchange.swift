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

public protocol Exchange: AnyObject {

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
        
        let sortedVersions = versions.sorted { $0.timestamp < $1.timestamp }

        func batchSizeCostEvaluator(index: Int) -> Float {
            let batchDataSizeLimit = 5000000 // 5MB
            let version = sortedVersions[index]
            return Float(version.valueDataSize ?? 100000) / Float(batchDataSizeLimit) // Default to 100KB if we don't know size
        }

        let dynamicBatcher = DynamicTaskBatcher(numberOfTasks: sortedVersions.count, taskCostEvaluator: batchSizeCostEvaluator) { range, finishBatch in
            let batchVersions = Array(sortedVersions[range])
            self.retrieveValueChanges(forVersionsIdentifiedBy: batchVersions.ids) { result in
                autoreleasepool {
                    switch result {
                    case let .failure(error):
                        log.error("Failed adding to history: \(error)")
                        finishBatch(.definitive(.failure(error)))
                    case let .success(valueChangesByVersionIdentifier):
                        let valueChangesByVersionID: [Version.ID:[Value.Change]] = valueChangesByVersionIdentifier.reduce(into: [:]) { result, keyValue in
                            var version = versionsByIdentifier[keyValue.key]!
                            if version.valueDataSize == nil { version.valueDataSize = keyValue.value.valueDataSize }
                            result[version.id] = keyValue.value
                        }
                        self.addToHistory(sortedVersions: batchVersions, valueChangesByVersionID: valueChangesByVersionID) { result in
                            switch result {
                            case .success:
                                finishBatch(.definitive(.success(())))
                            case .failure(let error):
                                if let exchangeError = error as? ExchangeError, case .remoteVersionsWithUnknownPredecessors = exchangeError {
                                    finishBatch(.growBatchAndReexecute)
                                } else {
                                    finishBatch(.definitive(.failure(error)))
                                }
                            }
                        }
                    }
                }
            }
        }
        dynamicBatcher.start(executingUponCompletion: completionHandler)
    }
    
    /// Note that we don't mutate the dictionary, because that results in a large memory copy.
    private func addToHistory(sortedVersions: [Version], valueChangesByVersionID: [Version.ID:[Value.Change]], executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        if sortedVersions.isEmpty {
            log.trace("No versions. Finished adding to history")
            completionHandler(.success(()))
        } else if let version = appendableVersion(from: sortedVersions) {
            autoreleasepool {
                let valueChanges = valueChangesByVersionID[version.id]!
                log.trace("Adding version to store: \(version.id.rawValue)")
                log.verbose("Value changes for \(version.id.rawValue): \(valueChanges)")

                do {
                    try self.store.addVersion(version, storing: valueChanges)
                } catch Store.Error.attemptToAddExistingVersion {
                    log.error("Failed adding to history because version already exists. Ignoring error")
                } catch {
                    log.error("Failed adding to history: \(error)")
                    completionHandler(.failure(error))
                    return
                }
                
                let reducedVersions = sortedVersions.filter { $0.id != version.id }
                
                // Dispatch so that we don't end up with a huge recursive call stack
                DispatchQueue.global(qos: .userInitiated).async {
                    autoreleasepool {
                        // Note that we just pass along all value changes, because any modification of the dictionary will result in a large copy
                        self.addToHistory(sortedVersions: reducedVersions, valueChangesByVersionID: valueChangesByVersionID, executingUponCompletion: completionHandler)
                    }
                }
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
        let sendVersions = AsynchronousTask { finishAsyncTask in
            toSendIds = self.versionIdsMissingRemotely(forRemoteIdentifiers: remoteIds)
            
            func batchSizeCostEvaluator(index: Int) -> Float {
                let batchDataSizeLimit: Int64 = 5000000 // 5MB
                let defaultDataSize: Int64 = 100000 // 100KB
                if let version = try? self.store.version(identifiedBy: toSendIds[index]) {
                    return Float(version.valueDataSize ?? defaultDataSize) / Float(batchDataSizeLimit)
                } else {
                    return Float(defaultDataSize) / Float(batchDataSizeLimit)
                }
            }
            
            let taskBatcher = DynamicTaskBatcher(numberOfTasks: toSendIds.count, taskCostEvaluator: batchSizeCostEvaluator) { range, finishBatch in
                do {
                    let versionChanges: [VersionChanges] = try toSendIds!.map { versionId in
                        guard let version = try self.store.version(identifiedBy: versionId) else {
                            throw ExchangeError.missingVersion
                        }
                        let changes = try self.store.valueChanges(madeInVersionIdentifiedBy: versionId)
                        return (version, changes)
                    }
                    
                    guard !versionChanges.isEmpty else {
                        finishBatch(.definitive(.success(())))
                        return
                    }
                    
                    self.send(versionChanges: versionChanges) { result in
                        finishBatch(.definitive(result))
                    }
                } catch {
                    finishBatch(.definitive(.failure(error)))
                }
            }
            taskBatcher.start(executingUponCompletion: finishAsyncTask)
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
