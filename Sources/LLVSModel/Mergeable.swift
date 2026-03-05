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

// MARK: - Property Merge Helpers

public func mergeProperty<T: Equatable>(_ dominant: T, _ subordinate: T, _ ancestor: T) throws -> T {
    dominant == ancestor ? subordinate : dominant
}

public func mergeProperty<T: Mergeable>(_ dominant: T, _ subordinate: T, _ ancestor: T) throws -> T {
    try dominant.merged(withSubordinate: subordinate, commonAncestor: ancestor)
}

public func salvageProperty<T: Equatable>(_ dominant: T, _ subordinate: T) throws -> T {
    dominant
}

public func salvageProperty<T: Mergeable>(_ dominant: T, _ subordinate: T) throws -> T {
    try dominant.salvaging(from: subordinate)
}

// MARK: - Optional Mergeable

extension Optional: Mergeable where Wrapped: Mergeable {
    public func merged(withSubordinate other: Self, commonAncestor: Self) throws -> Self {
        switch (self, other, commonAncestor) {
        case let (.some(d), .some(s), .some(a)):
            return try .some(d.merged(withSubordinate: s, commonAncestor: a))
        case (.some(let d), .none, .some(let a)):
            return d == a ? other : self
        case (.none, _, .some):
            return self
        case (_, _, .none):
            return self
        }
    }

    public func salvaging(from other: Self) throws -> Self {
        switch (self, other) {
        case let (.some(d), .some(s)):
            return try .some(d.salvaging(from: s))
        default:
            return self
        }
    }
}
