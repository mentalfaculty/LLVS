//
//  Exchange.swift
//  LLVS
//
//  Created by Drew McCormack on 25/02/2019.
//

import Foundation

public protocol ExchangeClient: class {
    func newVersionsAreAvailable(via exchange: Exchange)
}

public protocol Exchange {
    var client: ExchangeClient? { get set }
    var store: Store { get }
    
    func retrieve(executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.Identifier]>)
    func retrieveAllVersionIdentifiers(executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.Identifier]>)
    func retrieveVersions(identifiedBy versionIdentifiers: [Version.Identifier], executingUponCompletion completionHandler: @escaping CompletionHandler<[Version]>)
    func retrieveValueChanges(forVersionIdentifiedBy versionIdentifier: Version.Identifier, executingUponCompletion completionHandler: @escaping CompletionHandler<[Value.Change]>)

    func send(executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.Identifier]>)
    func send(_ version: Version, with valueChanges: [Value.Change], executingUponCompletion completionHandler: @escaping CompletionHandler<Void>)
}

public extension Exchange {
    
    func retrieve(executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.Identifier]>) {
        retrieveAllVersionIdentifiers { result in
            switch result {
            case let .failure(error):
                completionHandler(.failure(error))
            case let .success(versionIds):
                var toRetrieveIds: [Version.Identifier]!
                self.store.queryHistory { history in
                    let storeVersionIds = Set(history.allVersionIdentifiers)
                    let remoteVersionIds = Set(versionIds)
                    toRetrieveIds = Array(remoteVersionIds.subtracting(storeVersionIds))
                }
                self.retrieveVersions(identifiedBy: toRetrieveIds, executingUponCompletion: completionHandler)
            }
        }
    }
    
    func retrieveVersions(identifiedBy versionIdentifiers: [Version.Identifier], executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.Identifier]>) {
    
    }

    func send(executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.Identifier]>) {
        
    }
}
