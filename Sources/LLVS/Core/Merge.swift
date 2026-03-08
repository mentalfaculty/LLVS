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
    public var forksByValueIdentifier: [Value.ID:Value.Fork] = [:]
    
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

        // Collect all value IDs that need fetching from the favored branch
        var idsToFetch: [Value.ID] = []
        for (valueId, fork) in merge.forksByValueIdentifier {
            switch fork {
            case let .removedAndUpdated(removeBranch) where removeBranch != favoredBranch:
                idsToFetch.append(valueId)
            case .twiceInserted, .twiceUpdated:
                idsToFetch.append(valueId)
            default:
                break
            }
        }

        // Batch-fetch all needed values in one Zone query
        let fetchedValues = try store.values(forIds: idsToFetch, at: favoredVersion.id)
        let valuesByID = Dictionary(zip(idsToFetch, fetchedValues).compactMap { id, val in val.map { (id, $0) } }, uniquingKeysWith: { a, _ in a })

        var changes: [Value.Change] = []
        for (valueId, fork) in merge.forksByValueIdentifier {
            switch fork {
            case let .removedAndUpdated(removeBranch):
                if removeBranch == favoredBranch {
                    changes.append(.preserveRemoval(valueId))
                } else {
                    changes.append(.preserve(valuesByID[valueId]!.reference!))
                }
            case .twiceInserted, .twiceUpdated:
                changes.append(.preserve(valuesByID[valueId]!.reference!))
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

        // Collect value IDs by what branches they need fetching from
        var idsFromFirst: [Value.ID] = []
        var idsFromSecond: [Value.ID] = []
        var removedAndUpdatedIds: [(valueId: Value.ID, fromVersion: Version)] = []
        for (valueId, fork) in merge.forksByValueIdentifier {
            switch fork {
            case let .removedAndUpdated(removeBranch):
                let favoredVersion = removeBranch.opposite == .first ? v.first : v.second
                removedAndUpdatedIds.append((valueId, favoredVersion))
            case .twiceInserted, .twiceUpdated:
                idsFromFirst.append(valueId)
                idsFromSecond.append(valueId)
            default:
                break
            }
        }

        // Batch-fetch values from both branches
        let allIdsFromFirst = idsFromFirst + removedAndUpdatedIds.filter { $0.fromVersion.id == v.first.id }.map { $0.valueId }
        let allIdsFromSecond = idsFromSecond + removedAndUpdatedIds.filter { $0.fromVersion.id == v.second.id }.map { $0.valueId }
        let valuesFirst = try store.values(forIds: allIdsFromFirst, at: v.first.id)
        let valuesSecond = try store.values(forIds: allIdsFromSecond, at: v.second.id)
        let firstByID = Dictionary(zip(allIdsFromFirst, valuesFirst).compactMap { id, val in val.map { (id, $0) } }, uniquingKeysWith: { a, _ in a })
        let secondByID = Dictionary(zip(allIdsFromSecond, valuesSecond).compactMap { id, val in val.map { (id, $0) } }, uniquingKeysWith: { a, _ in a })

        // Query history once for all stored version IDs needed for timestamp comparison
        let allStoredVersionIds = Set(
            (idsFromFirst.compactMap { firstByID[$0]?.storedVersionId }) +
            (idsFromSecond.compactMap { secondByID[$0]?.storedVersionId })
        )
        var versionsByStoredID: [Version.ID: Version] = [:]
        store.queryHistory { history in
            for svid in allStoredVersionIds {
                if let ver = history.version(identifiedBy: svid) {
                    versionsByStoredID[svid] = ver
                }
            }
        }

        var changes: [Value.Change] = []
        for (valueId, fork) in merge.forksByValueIdentifier {
            switch fork {
            case let .removedAndUpdated(removeBranch):
                let value = removeBranch.opposite == .first ? firstByID[valueId]! : secondByID[valueId]!
                changes.append(.preserve(value.reference!))
            case .twiceInserted, .twiceUpdated:
                let value1 = firstByID[valueId]!
                let value2 = secondByID[valueId]!
                let version1 = versionsByStoredID[value1.storedVersionId!]!
                let version2 = versionsByStoredID[value2.storedVersionId!]!
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

