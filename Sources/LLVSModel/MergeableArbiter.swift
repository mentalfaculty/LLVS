//
//  MergeableArbiter.swift
//  LLVS
//
//  Created by Drew McCormack on 01/03/2026.
//

import Foundation
import LLVS

/// A `MergeArbiter` that bridges LLVS merge conflicts to
/// `Mergeable.merged(withSubordinate:commonAncestor:)` for property-wise resolution.
///
/// Register each `StorableModel & Mergeable` type before merging. Unregistered
/// value types fall through to `fallbackArbiter`.
public class MergeableArbiter: MergeArbiter {

    /// Type-erased merge closure: `(dominant, subordinate, ancestor?) -> merged`
    private var registry: [String: (Data, Data, Data?) throws -> Data] = [:]

    /// Arbiter used for values whose `Value.ID` has no registered type prefix.
    public var fallbackArbiter: MergeArbiter

    public init(fallbackArbiter: MergeArbiter = MostRecentChangeFavoringArbiter()) {
        self.fallbackArbiter = fallbackArbiter
    }

    /// Register a `StorableModel & Mergeable` type so its conflicts are resolved
    /// with property-wise 3-way merge.
    public func register<T: StorableModel & Mergeable>(_ type: T.Type) {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        registry[T.modelTypeIdentifier] = { dominantData, subordinateData, ancestorData in
            let dominant = try decoder.decode(T.self, from: dominantData)
            let subordinate = try decoder.decode(T.self, from: subordinateData)
            let merged: T
            if let ancestorData {
                let ancestor = try decoder.decode(T.self, from: ancestorData)
                merged = try dominant.merged(withSubordinate: subordinate, commonAncestor: ancestor)
            } else {
                merged = try dominant.salvaging(from: subordinate)
            }
            return try encoder.encode(merged)
        }
    }

    // MARK: - MergeArbiter

    public func changes(toResolve merge: Merge, in store: Store) throws -> [Value.Change] {
        // Split forks into registered (model) and unregistered (fallback)
        var modelForks: [Value.ID: Value.Fork] = [:]
        var fallbackForks: [Value.ID: Value.Fork] = [:]

        for (valueId, fork) in merge.forksByValueIdentifier {
            guard fork.isConflicting else { continue }
            if let typeId = modelTypeIdentifier(from: valueId), registry[typeId] != nil {
                modelForks[valueId] = fork
            } else {
                fallbackForks[valueId] = fork
            }
        }

        // Resolve model forks with Mergeable
        var changes: [Value.Change] = []
        let v = merge.versions

        for (valueId, fork) in modelForks {
            switch fork {
            case .twiceUpdated:
                let firstValue = try store.value(id: valueId, at: v.first.id)!
                let secondValue = try store.value(id: valueId, at: v.second.id)!
                var ancestorData: Data? = nil
                if let ancestor = merge.commonAncestor {
                    ancestorData = try store.value(id: valueId, at: ancestor.id)?.data
                }
                let typeId = modelTypeIdentifier(from: valueId)!
                let mergedData = try registry[typeId]!(firstValue.data, secondValue.data, ancestorData)
                changes.append(.update(Value(id: valueId, data: mergedData)))

            case .twiceInserted:
                let firstValue = try store.value(id: valueId, at: v.first.id)!
                let secondValue = try store.value(id: valueId, at: v.second.id)!
                let typeId = modelTypeIdentifier(from: valueId)!
                // No ancestor for twice-inserted
                let mergedData = try registry[typeId]!(firstValue.data, secondValue.data, nil)
                changes.append(.update(Value(id: valueId, data: mergedData)))

            case .removedAndUpdated(let removedOn):
                // Favor the update (preserve the non-removed branch's value)
                let updatedVersion = removedOn == .first ? v.second : v.first
                let value = try store.value(id: valueId, at: updatedVersion.id)!
                changes.append(.preserve(value.reference!))

            default:
                break
            }
        }

        // Resolve fallback forks
        if !fallbackForks.isEmpty {
            var fallbackMerge = merge
            fallbackMerge.forksByValueIdentifier = fallbackForks
            let fallbackChanges = try fallbackArbiter.changes(toResolve: fallbackMerge, in: store)
            changes.append(contentsOf: fallbackChanges)
        }

        return changes
    }
}
