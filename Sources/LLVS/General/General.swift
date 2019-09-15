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

public extension ClosedRange where Bound == Int {
    func split(intoRangesOfLength size: Bound) -> [ClosedRange] {
        let end = upperBound+1
        return stride(from: lowerBound, to: end, by: size).map {
            ClosedRange(uncheckedBounds: (lower: $0, upper: Swift.min($0+size-1, upperBound)))
        }
    }
}
