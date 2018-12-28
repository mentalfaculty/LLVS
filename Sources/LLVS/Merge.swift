//
//  Resolver.swift
//  LLVS
//
//  Created by Drew McCormack on 19/12/2018.
//

import Foundation


public struct Merge {
    
    public struct Conflict {
        var values: (Value?, Value?)
        var originalValue: Value?
    }
    
    public var commonAncestor: Version
    public var versions: (Version, Version)
    public var conflicts: [Conflict] = []
    public var insertedValues: [Value] = []
    public var updatedValues: [Value] = []
    public var identifiersOfRemovedValues: [Value.Identifier] = []
    
    internal init(versions: (Version, Version), commonAncestor: Version) {
        self.commonAncestor = commonAncestor
        self.versions = versions
    }
    
}


protocol Arbiter {
    
    func merge(byResolving merge: Merge, in store: Store) -> Merge
    
}
