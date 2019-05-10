//
//  Merge.swift
//  LLVS
//
//  Created by Drew McCormack on 19/12/2018.
//

import Foundation

public struct Merge {
    
    public var commonAncestor: Version?
    public var versions: (first: Version, second: Version)
    public var forksByValueIdentifier: [Value.Identifier:Value.Fork] = [:]
    
    public init(versions: (first: Version, second: Version), commonAncestor: Version?) {
        self.commonAncestor = commonAncestor
        self.versions = versions
    }

}

public protocol MergeArbiter {
    
    func changes(toResolve merge: Merge, in store: Store) throws -> [Value.Change]
    
}

/// When conflicting, always favor the branch with the most recent version.
public class MostRecentBranchFavoringArbiter: MergeArbiter {
    
    public init() {}

    public func changes(toResolve merge: Merge, in store: Store) throws -> [Value.Change] {
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

/// Favors the most recent change on a conflict by conflict basis.
/// Will pick an update over a removal, regardless of recency.
public class MostRecentChangeFavoringArbiter: MergeArbiter {
    
    public init() {}
    
    public func changes(toResolve merge: Merge, in store: Store) throws -> [Value.Change] {
        let v = merge.versions
        var changes: [Value.Change] = []
        for (valueId, fork) in merge.forksByValueIdentifier {
            switch fork {
            case let .removedAndUpdated(removeBranch):
                let favoredVersion = removeBranch.opposite == .first ? v.first : v.second
                let value = try store.value(valueId, prevailingAt: favoredVersion.identifier)!
                changes.append(.preserve(value.reference!))
            case .twiceInserted, .twiceUpdated:
                let value1 = try store.value(valueId, prevailingAt: v.first.identifier)!
                var version1: Version!
                store.queryHistory { version1 = $0.version(identifiedBy: value1.version!) }
                
                let value2 = try store.value(valueId, prevailingAt: v.second.identifier)!
                var version2: Version!
                store.queryHistory { version2 = $0.version(identifiedBy: value2.version!) }
                
                if version1.timestamp >= version2.timestamp {
                    changes.append(.preserve(value1.reference!))
                } else {
                    changes.append(.preserve(value2.reference!))
                }
            case .inserted, .removed, .updated, .twiceRemoved:
                break
            }
        }
        return changes
    }
    
}

