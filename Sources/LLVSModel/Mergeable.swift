//
//  Mergeable.swift
//  LLVS
//
//  Created by Drew McCormack on 04/03/2026.
//

import Foundation

/// A type that supports property-wise 3-way merge.
///
/// Conform to this protocol (typically via the `@MergeableModel` macro) to enable
/// automatic conflict resolution in `MergeableArbiter`.
public protocol Mergeable: Equatable {
    /// Merge `self` (dominant) with `other` (subordinate), using `commonAncestor`
    /// to determine which properties changed on each branch.
    func merged(withSubordinate other: Self, commonAncestor: Self) throws -> Self

    /// Resolve a conflict when no common ancestor is available (e.g. twice-inserted).
    /// Default: returns `self` (dominant wins).
    func salvaging(from other: Self) throws -> Self
}

public extension Mergeable {
    func salvaging(from other: Self) throws -> Self {
        self
    }
}
