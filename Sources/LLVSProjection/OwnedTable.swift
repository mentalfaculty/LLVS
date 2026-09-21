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
///
/// **Drive one table from one place.** Capture is suppressed while a version from elsewhere
/// is applied, and that suppression is a row in the database, so it is global to the table
/// rather than per-connection or per-thread. An app writing while `apply` runs therefore has
/// its write swallowed: the row changes, nothing is captured, and the edit never becomes a
/// version. The row still shows the edit, so nothing looks wrong until the data fails to
/// sync. `apply` takes the write lock before suppressing, which makes a writer on another
/// connection wait, but nothing can protect a second thread sharing this one. Serialise
/// access — an actor, a queue, or simply one owner — as `SQLiteDatabase` already requires.
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
    var stateName: String { "\(tableName)_state" }

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

        // The version this table is a working copy of. Recorded here rather than left to the
        // caller, because a drain that forgets it bases a version on nothing and silently
        // starts a second root: two heads and a forked history, from one device that never
        // synced with anything.
        statements.append("""
            CREATE TABLE IF NOT EXISTS \(stateName) (
                id INTEGER PRIMARY KEY CHECK (id = 0),
                version_id TEXT
            )
            """)
        statements.append("""
            INSERT INTO \(stateName) (id, version_id)
                SELECT 0, NULL WHERE NOT EXISTS (SELECT 1 FROM \(stateName))
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
        // A table with no columns beyond the identifier has nothing an update could change,
        // and SQLite rejects a trigger with an empty body.
        if !schema.columns.isEmpty {
            statements.append("""
                CREATE TRIGGER IF NOT EXISTS \(tableName)_capture_update AFTER UPDATE ON \(tableName)
                WHEN \(notSuppressed)
                BEGIN
                \(updateBody)END
                """)
        }

        statements.append("""
            CREATE TRIGGER IF NOT EXISTS \(tableName)_capture_delete AFTER DELETE ON \(tableName)
            WHEN \(notSuppressed)
            BEGIN
                INSERT INTO \(changelogName) (llvs_id, column_name, op) VALUES (OLD.llvs_id, NULL, 'd');
            END
            """)

        return statements
    }

    /// Whether a value belongs to this table, by the type suffix of its ID.
    ///
    /// A change set from `Store.valueChanges(updatingFrom:to:)` carries every type in the
    /// store, so without this each owned table would write every value, landing rows with
    /// null columns or — where property names collide — real but wrong data.
    func owns(_ valueId: Value.ID) -> Bool {
        guard let slashIndex = valueId.rawValue.lastIndex(of: "/") else { return false }
        return valueId.rawValue[valueId.rawValue.index(after: slashIndex)...] == typeIdentifier
    }

    /// The version this table is a working copy of, or nil before anything has been drained
    /// or applied.
    ///
    /// This is the table's own record, so an app need not remember it across a launch. A
    /// drain based on nothing when the store already holds versions starts a second root.
    public func currentVersion(in database: SQLiteDatabase) throws -> Version.ID? {
        var rawValue: String?
        try database.forEach(matchingQuery: "SELECT version_id FROM \(stateName) WHERE id = 0") { row in
            rawValue = row.value(inColumnAtIndex: 0)
        }
        return rawValue.map { Version.ID($0) }
    }

    /// Records the version this table now reflects. Call inside the same transaction as the
    /// rows it describes, so the marker cannot claim a version whose rows did not land.
    func setCurrentVersion(_ version: Version.ID, in database: SQLiteDatabase) throws {
        try database.execute(
            statement: """
                INSERT INTO \(stateName) (id, version_id) VALUES (0, ?)
                ON CONFLICT(id) DO UPDATE SET version_id = excluded.version_id
                """,
            withBindingsList: [[version.rawValue]])
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
    ///
    /// The flag is global to the table, so any write from anywhere during `block` is
    /// swallowed, not only the ones this made. Call it with the write lock already held, as
    /// `apply` does, and never from two places at once.
    public func whileApplyingRemoteChanges(in database: SQLiteDatabase, _ block: () throws -> Void) throws {
        try database.execute(statement: "UPDATE \(suppressionName) SET flag = 1")
        defer {
            do {
                try database.execute(statement: "UPDATE \(suppressionName) SET flag = 0")
            } catch {
                // Leaving the flag set silently discards every later local write, so this is
                // worth saying out loud even though there is nothing to be done about it here.
                log.error("Could not lift capture suppression on \(tableName): \(error). Local writes will not be captured until it is cleared.")
            }
        }
        try block()
    }
}
