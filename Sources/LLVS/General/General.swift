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

public extension Result {
    var value: Success? {
        guard case let .success(value) = self else { return nil }
        return value
    }
    
    var voidResult: Result<Void, Error> {
        switch self {
        case let .failure(error):
            return .failure(error)
        case .success:
            return .success(())
        }
    }

    var isSuccess: Bool {
        switch self {
        case .failure:
            return false
        case .success:
            return true
        }
    }
}

public typealias CompletionHandler<T> = (Result<T, Error>)->Void

public extension ClosedRange where Bound == Int {
    func split(intoRangesOfLength size: Bound) -> [ClosedRange] {
        let end = upperBound+1
        return stride(from: lowerBound, to: end, by: size).map {
            ClosedRange(uncheckedBounds: (lower: $0, upper: Swift.min($0+size-1, upperBound)))
        }
    }
}
