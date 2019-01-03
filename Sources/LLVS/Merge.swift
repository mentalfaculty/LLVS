//
//  Resolver.swift
//  LLVS
//
//  Created by Drew McCormack on 19/12/2018.
//

import Foundation


public struct Merge {
    
    public var commonAncestor: Version
    public var versions: (first: Version, second: Version)
    public var diffsByValueIdentifier: [Value.Identifier:Value.Diff] = [:]
    public var updatedValues: [Value] = []
    public var identifiersOfRemovedValues: [Value.Identifier] = []
    
    internal init(versions: (first: Version, second: Version), commonAncestor: Version) {
        self.commonAncestor = commonAncestor
        self.versions = versions
    }
    
}


protocol Arbiter {
    
    func resolvedMerge(byResolvingConflictsIn merge: inout Merge, in store: Store)
    
}
