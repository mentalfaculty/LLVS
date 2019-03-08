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
    
    func changes(toResolve merge: Merge, in store: Store) throws -> [Value.Change]
    
}

/// When conflicting, always favor the branch with the most recent version.
class MostRecentBranchFavoringArbiter: MergeArbiter {
    
    func changes(toResolve merge: Merge, in store: Store) throws -> [Value.Change] {
        let v = merge.versions
        let favoredBranch: Value.Fork.Branch = v.first.timestamp >= v.second.timestamp ? .first : .second
        let favoredVersion = favoredBranch == .first ? v.first : v.second
        var changes: [Value.Change] = []
        for (valueId, fork) in merge.forksByValueIdentifier {
            switch fork {
            case let .removedAndUpdated(removeBranch):
                if removeBranch == favoredBranch {
                    changes.append(.preserveRemoval(valueId))
                } else {
                    let value = try store.value(valueId, prevailingAt: favoredVersion.identifier)!
                    changes.append(.preserve(value.reference!))
                }
            case .twiceInserted, .twiceUpdated:
                let value = try store.value(valueId, prevailingAt: favoredVersion.identifier)!
                changes.append(.preserve(value.reference!))
            case .inserted, .removed, .updated, .twiceRemoved:
                break
            }
        }
        return changes
    }
    
}
