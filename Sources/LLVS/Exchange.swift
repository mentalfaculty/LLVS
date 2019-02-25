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

public protocol Exchange {
    
    func retrieveRemoteVersionIdentifiers(executingUponCompletion completionHandler: @escaping (ExchangeResult<[Version.Identifier]>)->Void)
    func retrieveRemoteVersion(identifiedBy versionIdentifier: Version.Identifier, executingUponCompletion completionHandler: @escaping (ExchangeResult<Version>)->Void)
    func retrieveRemoteChanges(forVersionIdentifiedBy versionIdentifier: Version.Identifier, executingUponCompletion completionHandler: @escaping (ExchangeResult<Value.Change>)->Void)
    
}
