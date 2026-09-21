//
//  MergeableModelMacro.swift
//  LLVS
//
//  Created by Drew McCormack on 04/03/2026.
//

import SwiftSyntax
import SwiftSyntaxMacros

/// SQLite keywords that cannot stand as a bare column name. A colliding name takes a
/// trailing underscore rather than being quoted, so the column stays a plain identifier and
/// needs no escaping wherever it appears.
private let sqliteKeywords: Set<String> = [
    "abort", "action", "add", "after", "all", "alter", "always", "analyze", "and", "as",
    "asc", "attach", "autoincrement", "before", "begin", "between", "by", "cascade", "case",
    "cast", "check", "collate", "column", "commit", "conflict", "constraint", "create",
    "cross", "current", "database", "default", "deferrable", "deferred", "delete", "desc",
    "detach", "distinct", "do", "drop", "each", "else", "end", "escape", "except",
    "exclusive", "exists", "explain", "fail", "filter", "first", "following", "for",
    "foreign", "from", "full", "glob", "group", "having", "if", "ignore", "immediate",
    "in", "index", "indexed", "initially", "inner", "insert", "instead", "intersect",
    "into", "is", "isnull", "join", "key", "last", "left", "like", "limit", "match",
    "natural", "no", "not", "notnull", "null", "of", "offset", "on", "or", "order",
    "outer", "over", "plan", "pragma", "primary", "query", "raise", "range", "recursive",
    "references", "regexp", "reindex", "release", "rename", "replace", "restrict",
    "right", "rollback", "row", "savepoint", "select", "set", "table", "temp", "temporary",
    "then", "to", "transaction", "trigger", "union", "unique", "update", "using",
    "vacuum", "values", "view", "virtual", "when", "where", "window", "with", "without",
]

/// A property name in camelCase becomes a conventional snake_case column, escaped if it
/// collides with a keyword.
private func columnName(forProperty property: String) -> String {
    var result = ""
    for character in property {
        if character.isUppercase {
            if !result.isEmpty { result.append("_") }
            result.append(contentsOf: character.lowercased())
        } else {
            result.append(character)
        }
    }
    return sqliteKeywords.contains(result) ? result + "_" : result
}

/// The SQLite type for a declared Swift type, or nil when the type has no column shape and
/// the property should be stored as JSON.
///
/// An optional is the same column, nullable, so the wrapped type decides. `Bool` and `Date`
/// are both `INTEGER`, which is how SQLite holds them: 0 or 1, and seconds since 1970.
private func sqliteDeclaration(forSwiftType swiftType: String) -> String? {
    var bare = swiftType.trimmingCharacters(in: .whitespaces)
    if bare.hasSuffix("?") { bare = String(bare.dropLast()).trimmingCharacters(in: .whitespaces) }
    if bare.hasPrefix("Optional<") && bare.hasSuffix(">") {
        bare = String(bare.dropFirst("Optional<".count).dropLast()).trimmingCharacters(in: .whitespaces)
    }
    // A qualified name such as Foundation.Date names the same type.
    if let lastDot = bare.lastIndex(of: ".") {
        bare = String(bare[bare.index(after: lastDot)...])
    }

    switch bare {
    case "String": return "TEXT"
    case "Int", "Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32": return "INTEGER"
    case "Double", "Float": return "REAL"
    case "Bool": return "INTEGER"
    case "Date": return "INTEGER"
    case "UUID": return "TEXT"
    case "Data": return "BLOB"
    default: return nil
    }
}

/// A stored property, with its declared type when one is written down. The type is nil for
/// `var x = 0`, where it is inferred and therefore invisible to a macro.
private struct StoredProperty {
    let name: String
    let declaredType: String?
}

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

        let storedProperties = declaration.memberBlock.members.flatMap { member -> [StoredProperty] in
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { return [] }

            // Skip `let` constants
            guard varDecl.bindingSpecifier.tokenKind == .keyword(.var) else { return [] }

            // Skip static/class properties
            let isStatic = varDecl.modifiers.contains { modifier in
                modifier.name.tokenKind == .keyword(.static) || modifier.name.tokenKind == .keyword(.class)
            }
            guard !isStatic else { return [] }

            // A declaration can have several bindings: `var a = 0, b = 0`
            return varDecl.bindings.compactMap { binding -> StoredProperty? in
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

                return StoredProperty(
                    name: pattern.identifier.text,
                    declaredType: binding.typeAnnotation?.type.trimmedDescription)
            }
        }

        var mergedStatements = ["var result = self"]
        for prop in storedProperties.map(\.name) {
            mergedStatements.append("result.\(prop) = try mergeProperty(self.\(prop), other.\(prop), commonAncestor.\(prop))")
        }
        mergedStatements.append("return result")
        let mergedBody = mergedStatements.joined(separator: "\n        ")

        var salvagingStatements = ["var result = self"]
        for prop in storedProperties.map(\.name) {
            salvagingStatements.append("result.\(prop) = try salvageProperty(self.\(prop), other.\(prop))")
        }
        salvagingStatements.append("return result")
        let salvagingBody = salvagingStatements.joined(separator: "\n        ")

        // The SQLite schema. A scalar type gets a real column; a type that is written down
        // but has no column shape is stored as JSON; a type that is not written down at all
        // gets no column, because a macro sees only syntax and guessing would be wrong.
        var columnLiterals: [String] = []
        var propertiesWithoutColumns: [String] = []
        for property in storedProperties {
            let column = columnName(forProperty: property.name)
            guard let declaredType = property.declaredType else {
                propertiesWithoutColumns.append(property.name)
                continue
            }
            if let declaration = sqliteDeclaration(forSwiftType: declaredType) {
                columnLiterals.append("""
                    LLVSModel.ModelColumn(propertyName: "\(property.name)", columnName: "\(column)", declaration: "\(declaration)", storage: .scalar)
                    """)
            } else {
                columnLiterals.append("""
                    LLVSModel.ModelColumn(propertyName: "\(property.name)", columnName: "\(column)", declaration: "TEXT", storage: .json)
                    """)
            }
        }
        let columnsLiteral = columnLiterals.joined(separator: ",\n                ")
        let withoutColumnsLiteral = propertiesWithoutColumns.map { "\"\($0)\"" }.joined(separator: ", ")

        let extensionDecl: DeclSyntax = """
        extension \(type.trimmed): LLVSModel.Mergeable {
            \(raw: access)func merged(withSubordinate other: Self, commonAncestor: Self) throws -> Self {
                \(raw: mergedBody)
            }
            \(raw: access)func salvaging(from other: Self) throws -> Self {
                \(raw: salvagingBody)
            }
            \(raw: access)static var sqliteSchema: LLVSModel.ModelSchema {
                LLVSModel.ModelSchema(
                    columns: [
                \(raw: columnsLiteral)
                    ],
                    propertiesWithoutColumns: [\(raw: withoutColumnsLiteral)])
            }
        }
        """

        return [extensionDecl.cast(ExtensionDeclSyntax.self)]
    }
}
