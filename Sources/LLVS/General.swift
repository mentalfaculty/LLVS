//
//  General.swift
//  LLVS
//
//  Created by Drew McCormack on 04/11/2018.
//

import Foundation

public protocol StringIdentifiable {
    var identifierString: String { get }
}

public enum Result<ValueType> {
    case failure(Error)
    case success(ValueType)
    
    var value: ValueType? {
        guard case let .success(value) = self else { return nil }
        return value
    }
}

public typealias CompletionHandler<T> = (Result<T>)->Void


