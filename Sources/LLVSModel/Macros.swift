//
//  Macros.swift
//  LLVS
//
//  Created by Drew McCormack on 04/03/2026.
//

/// Generates a `Mergeable` conformance with property-wise 3-way merge.
///
/// Apply to a struct to automatically synthesize `merged(withSubordinate:commonAncestor:)`
/// and `salvaging(from:)`. All stored `var` properties are merged individually;
/// computed properties, static properties, and `let` constants are skipped.
@attached(extension, conformances: Mergeable, names: arbitrary)
public macro MergeableModel() = #externalMacro(module: "LLVSModelMacros", type: "MergeableModelMacro")
