//
//  OwnedTable.swift
//  LLVS
//
//  Created by Drew McCormack on 21/09/2026.
//

import Foundation
import LLVS
import LLVSModel
import LLVSSQLite

/// One row change recorded by an owned table's capture triggers.
public struct ChangelogEntry: Sendable, Equatable {

    public enum Operation: String, Sendable, Equatable {
        case insert = "i"
        case update = "u"
        case remove = "d"
    }

    public let sequence: Int64
    public let valueId: Value.ID

    /// Which column changed, for an update. Nil for an insert or a remove, which concern
    /// the whole row.
    public let columnName: String?

    public let operation: Operation
}

/// A SQLite table an app writes directly, whose changes become LLVS versions.
///
/// The table is ordinary: a real column per scalar property, `llvs_id` as the primary key,
/// and nothing else announcing LLVS. Index it, query it and write it as any SQLite table.
/// Think of it as a checkout — it holds the state at some version, and writing to it makes
/// a new one.
///
/// Three triggers record what changes into a changelog: per row, and for an update, per
/// column. That granularity is what lets two devices editing different columns of one row
/// both keep their edit.
public struct OwnedTable: Sendable {

    public let typeIdentifier: String
    public let tableName: String
    public let schema: ModelSchema

    public init(typeIdentifier: String, tableName: String, schema: ModelSchema) {
        precondition(ProjectedType.isPlainIdentifier(tableName),
            "Owned table name is not a plain SQL identifier: \"\(tableName)\"")
        for column in schema.columns {
            precondition(ProjectedType.isPlainIdentifier(column.columnName),
                "Owned table column name is not a plain SQL identifier: \"\(column.columnName)\"")
        }
        self.typeIdentifier = typeIdentifier
        self.tableName = tableName
        self.schema = schema
    }

    var changelogName: String { "\(tableName)_changelog" }
    var suppressionName: String { "\(tableName)_applying" }

    /// Everything needed to stand the table up, in the order it must run.
    public func createStatements() -> [String] {
        var statements: [String] = []

        let columnDeclarations = schema.columns.map { "\($0.columnName) \($0.declaration)" }
        let allColumns = (["llvs_id TEXT PRIMARY KEY"] + columnDeclarations).joined(separator: ", ")
        statements.append("CREATE TABLE IF NOT EXISTS \(tableName) (\(allColumns))")

        statements.append("""
            CREATE TABLE IF NOT EXISTS \(changelogName) (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                llvs_id TEXT NOT NULL,
                column_name TEXT,
                op TEXT NOT NULL
            )
            """)

        // A single row saying whether capture is suppressed. A table rather than a Swift
        // property because a trigger's WHEN clause is SQL and can consult only the database.
        statements.append("CREATE TABLE IF NOT EXISTS \(suppressionName) (flag INTEGER NOT NULL)")
        statements.append("""
            INSERT INTO \(suppressionName) (flag)
                SELECT 0 WHERE NOT EXISTS (SELECT 1 FROM \(suppressionName))
            """)

        let notSuppressed = "(SELECT flag FROM \(suppressionName)) = 0"

        statements.append("""
            CREATE TRIGGER IF NOT EXISTS \(tableName)_capture_insert AFTER INSERT ON \(tableName)
            WHEN \(notSuppressed)
            BEGIN
                INSERT INTO \(changelogName) (llvs_id, column_name, op) VALUES (NEW.llvs_id, NULL, 'i');
            END
            """)

        // One statement per column, each guarded so an unchanged column records nothing.
        // `IS NOT` rather than `<>` so a change to or from NULL is seen.
        var updateBody = ""
        for column in schema.columns {
            updateBody += """
                    INSERT INTO \(changelogName) (llvs_id, column_name, op)
                        SELECT NEW.llvs_id, '\(column.columnName)', 'u'
                        WHERE OLD.\(column.columnName) IS NOT NEW.\(column.columnName);

                """
        }
        statements.append("""
            CREATE TRIGGER IF NOT EXISTS \(tableName)_capture_update AFTER UPDATE ON \(tableName)
            WHEN \(notSuppressed)
            BEGIN
            \(updateBody)END
            """)

        statements.append("""
            CREATE TRIGGER IF NOT EXISTS \(tableName)_capture_delete AFTER DELETE ON \(tableName)
            WHEN \(notSuppressed)
            BEGIN
                INSERT INTO \(changelogName) (llvs_id, column_name, op) VALUES (OLD.llvs_id, NULL, 'd');
            END
            """)

        return statements
    }

    /// Everything captured so far, oldest first.
    public func changelogEntries(in database: SQLiteDatabase) throws -> [ChangelogEntry] {
        var entries: [ChangelogEntry] = []
        try database.forEach(matchingQuery: "SELECT seq, llvs_id, column_name, op FROM \(changelogName) ORDER BY seq") { row in
            guard let sequence: Int64 = row.value(inColumnAtIndex: 0),
                  let rawId: String = row.value(inColumnAtIndex: 1),
                  let rawOperation: String = row.value(inColumnAtIndex: 3),
                  let operation = ChangelogEntry.Operation(rawValue: rawOperation) else { return }
            entries.append(ChangelogEntry(
                sequence: sequence,
                valueId: .init(rawId),
                columnName: row.value(inColumnAtIndex: 2),
                operation: operation))
        }
        return entries
    }

    /// Removes every captured entry. Call only once they are safely in LLVS.
    public func clearChangelog(in database: SQLiteDatabase) throws {
        try database.execute(statement: "DELETE FROM \(changelogName)")
    }

    /// Removes entries up to and including `sequence`, leaving anything captured since.
    ///
    /// A drain reads the changelog and then turns it into a version, and the app may write
    /// in between. Clearing only what was read keeps those later writes for the next drain.
    public func clearChangelog(in database: SQLiteDatabase, throughSequence sequence: Int64) throws {
        try database.execute(statement: "DELETE FROM \(changelogName) WHERE seq <= ?",
            withBindingsList: [[sequence]])
    }

    /// Runs `block` with capture suppressed, for applying a version from elsewhere.
    ///
    /// Without this, an applied change would be recorded as a local edit and sent straight
    /// back out, and two devices would trade it indefinitely. The flag is lifted even when
    /// the block throws, or capture would stay off for good.
    public func whileApplyingRemoteChanges(in database: SQLiteDatabase, _ block: () throws -> Void) throws {
        try database.execute(statement: "UPDATE \(suppressionName) SET flag = 1")
        defer { try? database.execute(statement: "UPDATE \(suppressionName) SET flag = 0") }
        try block()
    }
}
