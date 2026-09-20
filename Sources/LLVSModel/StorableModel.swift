//
//  StorableModel.swift
//  LLVS
//
//  Created by Drew McCormack on 01/03/2026.
//

import Foundation
import LLVS

/// A type that can be stored as a typed model value in LLVS.
///
/// Conforming types get a stable `modelTypeIdentifier` (e.g. `"Contact"`)
/// used as a suffix in the LLVS `Value.ID`: `"uuid-string/Contact"`.
///
/// Does not require `Mergeable` — the `@MergeableModel` macro adds that
/// conformance separately.
public protocol StorableModel: Codable {
    static var modelTypeIdentifier: String { get }
}

// MARK: - Value.ID Helpers

/// Builds an LLVS `Value.ID` from a type identifier and instance identifier.
/// The format is `"instance-id/TypeName"`.
///
/// The instance identifier comes first so that the `Map` — which buckets values by the
/// first two characters of their ID — spreads instances of one type across many buckets.
/// With the type first, every instance of a type shared a single bucket, and each save
/// rewrote a node listing all of them.
public func modelValueID(typeIdentifier: String, instanceIdentifier: String) -> Value.ID {
    Value.ID("\(instanceIdentifier)/\(typeIdentifier)")
}

/// Extracts the model type identifier (suffix after the last `/`) from a `Value.ID`.
/// Returns `nil` if the ID contains no `/`.
///
/// The split is on the last slash, not the first, because an app-supplied instance
/// identifier may itself contain slashes. The type name is the part that must not split.
public func modelTypeIdentifier(from valueID: Value.ID) -> String? {
    guard let slashIndex = valueID.rawValue.lastIndex(of: "/") else { return nil }
    return String(valueID.rawValue[valueID.rawValue.index(after: slashIndex)...])
}

/// Extracts the instance identifier (everything before the last `/`) from a `Value.ID`.
/// Returns `nil` if the ID contains no `/`.
public func instanceIdentifier(from valueID: Value.ID) -> String? {
    guard let slashIndex = valueID.rawValue.lastIndex(of: "/") else { return nil }
    return String(valueID.rawValue[..<slashIndex])
}
