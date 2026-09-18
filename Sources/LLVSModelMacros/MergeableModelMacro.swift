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

        // The generated methods satisfy protocol requirements, so they need the access level of the struct
        let accessModifier = declaration.modifiers.first { modifier in
            [.keyword(.public), .keyword(.package)].contains(modifier.name.tokenKind)
        }
        let access = accessModifier.map { $0.name.text + " " } ?? ""

        let storedProperties = declaration.memberBlock.members.flatMap { member -> [String] in
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { return [] }

            // Skip `let` constants
            guard varDecl.bindingSpecifier.tokenKind == .keyword(.var) else { return [] }

            // Skip static/class properties
            let isStatic = varDecl.modifiers.contains { modifier in
                modifier.name.tokenKind == .keyword(.static) || modifier.name.tokenKind == .keyword(.class)
            }
            guard !isStatic else { return [] }

            // A declaration can have several bindings: `var a = 0, b = 0`
            return varDecl.bindings.compactMap { binding -> String? in
                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { return nil }

                // Skip computed properties
                if let accessorBlock = binding.accessorBlock {
                    switch accessorBlock.accessors {
                    case .getter:
                        // Shorthand computed property: `var x: T { ... }`
                        return nil
                    case .accessors(let accessorList):
                        let isComputed = accessorList.contains { accessor in
                            accessor.accessorSpecifier.tokenKind == .keyword(.get) ||
                            accessor.accessorSpecifier.tokenKind == .keyword(.set)
                        }
                        if isComputed { return nil }
                    }
                }

                return pattern.identifier.text
            }
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
            \(raw: access)func merged(withSubordinate other: Self, commonAncestor: Self) throws -> Self {
                \(raw: mergedBody)
            }
            \(raw: access)func salvaging(from other: Self) throws -> Self {
                \(raw: salvagingBody)
            }
        }
        """

        return [extensionDecl.cast(ExtensionDeclSyntax.self)]
    }
}
