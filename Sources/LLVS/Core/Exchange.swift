//
//  Exchange.swift
//  LLVS
//
//  Created by Drew McCormack on 25/02/2019.
//

import Foundation
import Combine

public enum ExchangeError: Swift.Error {
    case attemptToSendWithPeerToPeerExchange
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
    
    var isPeerToPeer: Bool { get }
    
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
        retrieveValueChanges(forVersionsIdentifiedBy: versions.ids) { result in
            switch result {
            case let .failure(error):
                log.error("Failed adding to history: \(error)")
                completionHandler(.failure(error))
            case let .success(valueChangesByVersionIdentifier):
                let valueChangesByVersion: [Version:[Value.Change]] = valueChangesByVersionIdentifier.reduce(into: [:]) { result, keyValue in
                    let version = versionsByIdentifier[keyValue.key]!
                    result[version] = keyValue.value
                }
                self.addToHistory(versionsWithValueChanges: valueChangesByVersion, executingUponCompletion: completionHandler)
            }
        }
    }
    
    private func addToHistory(versionsWithValueChanges: [Version:[Value.Change]], executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        let versions = Array(versionsWithValueChanges.keys)
        if versions.isEmpty {
            log.trace("No versions. Finished adding to history")
            completionHandler(.success(()))
        } else if let version = appendableVersion(from: versions) {
            let valueChanges = versionsWithValueChanges[version]!
            log.trace("Adding version to store: \(version.id.stringValue)")
            log.verbose("Value changes for \(version.id.stringValue): \(valueChanges)")
            
            do {
                try self.store.addVersion(version, storing: valueChanges)
            } catch Store.Error.attemptToAddExistingVersion {
                log.error("Failed adding to history because version already exists. Ignoring error")
            } catch {
                log.error("Failed adding to history: \(error)")
                completionHandler(.failure(error))
                return
            }
            
            var reducedVersions = versionsWithValueChanges
            reducedVersions[version] = nil
            self.addToHistory(versionsWithValueChanges: reducedVersions, executingUponCompletion: completionHandler)
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
        guard !isPeerToPeer else {
            completionHandler(.failure(ExchangeError.attemptToSendWithPeerToPeerExchange))
            return
        }
        
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
