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

    var newVersionsAvailable: AnyPublisher<Void, Never> { get }
    var store: Store { get }
    
    var restorationState: Data? { get set }
    
    func retrieve(executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.Identifier]>)
    func prepareToRetrieve(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>)
    func retrieveAllVersionIdentifiers(executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.Identifier]>)
    func retrieveVersions(identifiedBy versionIdentifiers: [Version.Identifier], executingUponCompletion completionHandler: @escaping CompletionHandler<[Version]>)
    func retrieveValueChanges(forVersionsIdentifiedBy versionIdentifiers: [Version.Identifier], executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.Identifier:[Value.Change]]>)

    func send(executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.Identifier]>)
    func prepareToSend(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>)
    func send(versionChanges: [VersionChanges], executingUponCompletion completionHandler: @escaping CompletionHandler<Void>)
}

// MARK:- Retrieving

public extension Exchange {
    
    func retrieve(executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.Identifier]>) {
        log.trace("Retrieving")
        
        let prepare = AsynchronousTask { finish in
            self.prepareToRetrieve { result in
                finish(result)
            }
        }
        
        var remoteIds: [Version.Identifier]!
        let retrieveIds = AsynchronousTask { finish in
            self.retrieveAllVersionIdentifiers { result in
                remoteIds = result.value
                finish(result.voidResult)
            }
        }
        
        var remoteVersions: [Version]!
        let retrieveVersions = AsynchronousTask { finish in
            let toRetrieveIds = self.versionIdentifiersMissingFromHistory(forRemoteIdentifiers: remoteIds)
            log.verbose("Version identifiers to retrieve: \(toRetrieveIds.identifierStrings)")
            self.retrieveVersions(identifiedBy: toRetrieveIds) { result in
                remoteVersions = result.value
                finish(result.voidResult)
            }
        }
        
        let addToHistory = AsynchronousTask { finish in
            log.verbose("Adding to history versions: \(remoteVersions.identifierStrings)")
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
    
    private func versionIdentifiersMissingFromHistory(forRemoteIdentifiers remoteIdentifiers: [Version.Identifier]) -> [Version.Identifier] {
        var toRetrieveIds: [Version.Identifier]!
        self.store.queryHistory { history in
            let storeVersionIds = Set(history.allVersionIdentifiers)
            let remoteVersionIds = Set(remoteIdentifiers)
            toRetrieveIds = Array(remoteVersionIds.subtracting(storeVersionIds))
        }
        return toRetrieveIds
    }
    
    private func addToHistory(_ versions: [Version], executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        let versionsByIdentifier = versions.reduce(into: [:]) { result, version in
            result[version.identifier] = version
        }
        retrieveValueChanges(forVersionsIdentifiedBy: versions.identifiers) { result in
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
            log.trace("Adding version to store: \(version.identifier.identifierString)")
            log.verbose("Value changes for \(version.identifier.identifierString): \(valueChanges)")
            
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
            return store.history(includesVersionsIdentifiedBy: v.predecessors?.identifiers ?? [])
        }
    }
    
}

// MARK:- Sending

public extension Exchange {
    
    func send(executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.Identifier]>) {
        let prepare = AsynchronousTask { finish in
            self.prepareToSend { result in
                finish(result)
            }
        }
        
        var remoteIds: [Version.Identifier]!
        let retrieveIds = AsynchronousTask { finish in
            self.retrieveAllVersionIdentifiers { result in
                remoteIds = result.value
                finish(result.voidResult)
            }
        }
        
        var toSendIds: [Version.Identifier]!
        let sendVersions = AsynchronousTask { finish in
            toSendIds = self.versionIdentifiersMissingRemotely(forRemoteIdentifiers: remoteIds)
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
    
    private func versionIdentifiersMissingRemotely(forRemoteIdentifiers remoteIdentifiers: [Version.Identifier]) -> [Version.Identifier] {
        var toSendIds: [Version.Identifier]!
        self.store.queryHistory { history in
            let storeVersionIds = Set(history.allVersionIdentifiers)
            let remoteVersionIds = Set(remoteIdentifiers)
            toSendIds = Array(storeVersionIds.subtracting(remoteVersionIds))
        }
        return toSendIds
    }
}
