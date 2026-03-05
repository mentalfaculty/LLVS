//
//  MergeableModelMacro.swift
//  LLVS
//
//  Created by Drew McCormack on 04/03/2026.
//

import SwiftSyntax
import SwiftSyntaxMacros

enum MergeableModelMacroError: Error, CustomStringConvertible {
    case onlyApplicableToStruct

    var description: String {
        switch self {
        case .onlyApplicableToStruct:
            return "@MergeableModel can only be applied to a struct"
        }
    }
}

public struct MergeableModelMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard declaration.is(StructDeclSyntax.self) else {
            throw MergeableModelMacroError.onlyApplicableToStruct
        }

        let storedProperties = declaration.memberBlock.members.compactMap { member -> String? in
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { return nil }

            // Skip `let` constants
            guard varDecl.bindingSpecifier.tokenKind == .keyword(.var) else { return nil }

            // Skip static/class properties
            let isStatic = varDecl.modifiers.contains { modifier in
                modifier.name.tokenKind == .keyword(.static) || modifier.name.tokenKind == .keyword(.class)
            }
            guard !isStatic else { return nil }

            guard let binding = varDecl.bindings.first,
                  let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
                return nil
            }

            // Skip computed properties (those with get/set accessors)
            if let accessorBlock = binding.accessorBlock {
                if case .accessors(let accessorList) = accessorBlock.accessors {
                    let isComputed = accessorList.contains { accessor in
                        accessor.accessorSpecifier.tokenKind == .keyword(.get) ||
                        accessor.accessorSpecifier.tokenKind == .keyword(.set)
                    }
                    if isComputed { return nil }
                }
            }

            return pattern.identifier.text
        }

        var mergedStatements = ["var result = self"]
        for prop in storedProperties {
            mergedStatements.append("result.\(prop) = try mergeProperty(self.\(prop), other.\(prop), commonAncestor.\(prop))")
        }
        mergedStatements.append("return result")
        let mergedBody = mergedStatements.joined(separator: "\n        ")

        var salvagingStatements = ["var result = self"]
        for prop in storedProperties {
            salvagingStatements.append("result.\(prop) = try salvageProperty(self.\(prop), other.\(prop))")
        }
        salvagingStatements.append("return result")
        let salvagingBody = salvagingStatements.joined(separator: "\n        ")

        let extensionDecl: DeclSyntax = """
        extension \(type.trimmed): LLVSModel.Mergeable {
            func merged(withSubordinate other: Self, commonAncestor: Self) throws -> Self {
                \(raw: mergedBody)
            }
            func salvaging(from other: Self) throws -> Self {
                \(raw: salvagingBody)
            }
        }
        """

        return [extensionDecl.cast(ExtensionDeclSyntax.self)]
    }
}
