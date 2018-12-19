//
//  Resolver.swift
//  LLVS
//
//  Created by Drew McCormack on 19/12/2018.
//

import Foundation


public struct Merge {
    
    public enum Resolution {
        case keepFirst
        case keepSecond
        case combine(updated: [Value], removed: [Value.Identifier])
    }
    
    public struct Conflict {
        var firstValue: Value
        var secondValue: Value
    }
    
    public var conflicts: [Conflict]
    public var updatedValues: [Value]
    public var removedValueIdentifiers: [Value.Identifier]
    
}


protocol Resolver {
    
    func merge(byResolving merge: Merge, in store: Store) -> Merge
    
}
