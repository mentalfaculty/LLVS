//
//  ProjectedType.swift
//  LLVS
//
//  Created by Drew McCormack on 20/09/2026.
//

import Foundation
import LLVS

/// A value bound into a SQLite statement.
public enum SQLiteValue: Sendable, Equatable {
    case text(String)
    case integer(Int64)
    case real(Double)
    case null
}

/// One indexed column in a projected table.
public struct ProjectedColumn: Sendable {
    public let name: String

    /// The SQLite type and any constraints, for example `"TEXT"` or `"INTEGER NOT NULL"`.
    public let declaration: String

    public init(name: String, declaration: String) {
        self.name = name
        self.declaration = declaration
    }
}

/// Describes how one stored model type becomes rows in a SQLite table.
///
/// A projection is an index, not a copy. Declare only the fields that are queried or
/// sorted on, and read the whole object from the store once a query has named the IDs.
/// That keeps the database small and the writes cheap, and it means adding a queryable
/// field later is a rebuild rather than a migration — the store still holds everything.
public struct ProjectedType: Sendable {

    /// The model type identifier. For `LLVSModel` types this is `modelTypeIdentifier`,
    /// which appears in the value ID after the last slash.
    public let typeIdentifier: String

    public let tableName: String

    public let columns: [ProjectedColumn]

    /// Decodes a stored value and returns its column values, keyed by column name.
    /// A column this omits is written as null.
    ///
    /// Throwing marks the value unreadable, which happens when another device wrote a
    /// model this build cannot decode. The projector then skips that value and reports
    /// its ID, rather than failing the whole pass.
    public let extract: @Sendable (Value) throws -> [String: SQLiteValue]

    /// - Precondition: `tableName` and every column name must be a plain SQL identifier —
    ///   a letter or underscore, then letters, digits or underscores. SQLite has no parameter
    ///   binding for identifiers, so these are written into the statement as they are given.
    ///   Checking here turns a typo into a clear failure at construction rather than a
    ///   puzzling syntax error at the first write.
    public init(
        typeIdentifier: String,
        tableName: String,
        columns: [ProjectedColumn],
        extract: @escaping @Sendable (Value) throws -> [String: SQLiteValue]
    ) {
        precondition(ProjectedType.isPlainIdentifier(tableName),
            "ProjectedType table name is not a plain SQL identifier: \"\(tableName)\"")
        for column in columns {
            precondition(ProjectedType.isPlainIdentifier(column.name),
                "ProjectedType column name is not a plain SQL identifier: \"\(column.name)\"")
        }

        self.typeIdentifier = typeIdentifier
        self.tableName = tableName
        self.columns = columns
        self.extract = extract
    }

    /// ASCII only, deliberately: `Character.isLetter` accepts letters from any script, which
    /// SQLite will not take in an unquoted identifier.
    static func isPlainIdentifier(_ name: String) -> Bool {
        guard let first = name.first else { return false }
        guard first.isASCII, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    /// The table always carries `llvs_id`, the value ID, as its primary key. That is what
    /// lets the projector upsert and delete rows by ID without decoding anything.
    public func createTableStatement() -> String {
        let declarations = columns.map { "\($0.name) \($0.declaration)" }
        let allColumns = (["llvs_id TEXT PRIMARY KEY"] + declarations).joined(separator: ", ")
        return "CREATE TABLE IF NOT EXISTS \(tableName) (\(allColumns))"
    }
}
