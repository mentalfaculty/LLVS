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
    public var forksByValueIdentifier: [Value.Identifier:Value.Fork] = [:]
    
    internal init(versions: (first: Version, second: Version), commonAncestor: Version) {
        self.commonAncestor = commonAncestor
        self.versions = versions
    }
    
}


protocol MergeArbiter {
    
    func changes(toResolve merge: Merge, in store: Store) -> [Value.Change]
    
}
