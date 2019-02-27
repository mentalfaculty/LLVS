//
//  Exchange.swift
//  LLVS
//
//  Created by Drew McCormack on 25/02/2019.
//

import Foundation

public enum ExchangeResult<ValueType> {
    case failure(Error)
    case success(ValueType)
}

public protocol ExchangeClient: class {
    func newVersionsAreAvailable(via exchange: Exchange)
}

public protocol Exchange {
    var client: ExchangeClient? { get set }
    
    func retrieveAllVersionIdentifiers(executingUponCompletion completionHandler: @escaping (ExchangeResult<[Version.Identifier]>)->Void)
    func retrieveVersion(identifiedBy versionIdentifier: Version.Identifier, executingUponCompletion completionHandler: @escaping (ExchangeResult<Version>)->Void)
    func retrieveValueChanges(forVersionIdentifiedBy versionIdentifier: Version.Identifier, executingUponCompletion completionHandler: @escaping (ExchangeResult<[Value.Change]>)->Void)

    func send(_ version: Version, with valueChanges: [Value.Change], executingUponCompletion completionHandler: @escaping (ExchangeResult<Void>)->Void)
}
