//
//  ModelValue.swift
//  LLVS
//
//  Created by Drew McCormack on 01/03/2026.
//

import Foundation
import LLVS

/// A type that can be stored as a typed model value in LLVS.
///
/// Conforming types get a stable `modelTypeIdentifier` (e.g. `"Contact"`)
/// used as a prefix in the LLVS `Value.ID`: `"Contact/uuid-string"`.
///
/// Does not require `Mergeable` — the `@ForkedModel` macro adds that
/// conformance separately.
public protocol ModelValue: Codable {
    static var modelTypeIdentifier: String { get }
}

// MARK: - Value.ID Helpers

/// Builds an LLVS `Value.ID` from a type identifier and instance identifier.
/// The format is `"TypeName/instance-id"`.
public func modelValueID(typeIdentifier: String, instanceIdentifier: String) -> Value.ID {
    Value.ID("\(typeIdentifier)/\(instanceIdentifier)")
}

/// Extracts the model type identifier (prefix before the first `/`) from a `Value.ID`.
/// Returns `nil` if the ID contains no `/`.
public func modelTypeIdentifier(from valueID: Value.ID) -> String? {
    guard let slashIndex = valueID.rawValue.firstIndex(of: "/") else { return nil }
    return String(valueID.rawValue[..<slashIndex])
}

/// Extracts the instance identifier (suffix after the first `/`) from a `Value.ID`.
/// Returns `nil` if the ID contains no `/`.
public func instanceIdentifier(from valueID: Value.ID) -> String? {
    guard let slashIndex = valueID.rawValue.firstIndex(of: "/") else { return nil }
    return String(valueID.rawValue[valueID.rawValue.index(after: slashIndex)...])
}
