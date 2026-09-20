//
//  Projector.swift
//  LLVS
//
//  Created by Drew McCormack on 20/09/2026.
//

import Foundation
import LLVS
import LLVSSQLite

/// What a single projection pass did.
public struct ProjectionResult: Sendable {

    /// Rows written or deleted.
    public let appliedCount: Int

    /// Values whose `ProjectedType.extract` refused them. These were skipped rather than
    /// applied, and the pass still completed: one value this build cannot decode does not
    /// hold up the rest. Report them, because to a reader they are simply missing.
    public let unreadableIds: [Value.ID]
}

/// Maintains a SQLite view of the current values in an LLVS store, so an app can query
/// by field rather than only by value ID.
///
/// Each pass asks the store what differs between the version the database holds and the
/// version it must reach, then applies that difference and the new version marker inside
/// one transaction. A failure part-way rolls the whole pass back, so the database is never
/// half-updated: it is either current or behind, and behind is repaired by running again.
///
/// The projection is never the truth. Deleting the database loses nothing, which is what
/// makes `rebuild(at:)` a routine operation rather than a last resort, and in turn what
/// makes changing the indexed columns a matter of raising `schemaVersion`.
///
/// Not thread-safe, and not safe to use from several tasks at once. Drive it from one place.
public final class Projector {

    private let database: SQLiteDatabase
    private let store: Store
    private let typesByIdentifier: [String: ProjectedType]
    private let schemaVersion: Int

    /// - Parameters:
    ///   - schemaVersion: The app's own number for the shape of its projected tables. Raise it
    ///     when the columns change, and the next pass rebuilds from the store instead of
    ///     diffing onto tables built for the old shape. There are no migrations.
    public init(database: SQLiteDatabase, store: Store, types: [ProjectedType], schemaVersion: Int) throws {
        self.database = database
        self.store = store
        self.typesByIdentifier = Dictionary(types.map { ($0.typeIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        self.schemaVersion = schemaVersion

        // The check constrains the table to a single row, so the version marker cannot fork.
        try database.execute(statement: """
            CREATE TABLE IF NOT EXISTS projection_state (
                id INTEGER PRIMARY KEY CHECK (id = 0),
                version_id TEXT,
                schema_version INTEGER NOT NULL
            )
            """)
        for type in types {
            try database.execute(statement: type.createTableStatement())
        }
    }

    /// The version the database currently reflects, or `nil` if nothing has been projected yet.
    public func projectedVersion() throws -> Version.ID? {
        var rawValue: String?
        try database.forEach(matchingQuery: "SELECT version_id FROM projection_state WHERE id = 0") { row in
            rawValue = row.value(inColumnAtIndex: 0)
        }
        return rawValue.map { Version.ID($0) }
    }

    /// The schema version the database was last written with, or `nil` if nothing has been projected.
    public func storedSchemaVersion() throws -> Int? {
        var rawValue: Int64?
        try database.forEach(matchingQuery: "SELECT schema_version FROM projection_state WHERE id = 0") { row in
            rawValue = row.value(inColumnAtIndex: 0)
        }
        return rawValue.map { Int($0) }
    }

    /// Brings the database to `version`, applying only what differs from what it already holds.
    ///
    /// Rebuilds instead when there is nothing to diff from: an empty database, or one written
    /// under a different `schemaVersion`, whose tables were built for another set of columns.
    @discardableResult
    public func update(to version: Version.ID) throws -> ProjectionResult {
        guard let projected = try projectedVersion(), try storedSchemaVersion() == schemaVersion else {
            return try rebuild(at: version)
        }
        guard projected != version else {
            return ProjectionResult(appliedCount: 0, unreadableIds: [])
        }
        let changes = try store.valueChanges(updatingFrom: projected, to: version)
        return try apply(changes, at: version, clearingFirst: false)
    }

    /// Empties the projected tables and projects every value at `version`.
    ///
    /// This is cheap in the sense that matters: the store holds everything, so the result is
    /// always correct. Use it on first run, after damage, and whenever the columns change.
    @discardableResult
    public func rebuild(at version: Version.ID) throws -> ProjectionResult {
        var changes: [Value.Change] = []
        try store.enumerate(version: version) { reference in
            if let value = try self.store.value(storedAt: reference) {
                changes.append(.insert(value))
            }
        }
        return try apply(changes, at: version, clearingFirst: true)
    }

    private func apply(_ changes: [Value.Change], at version: Version.ID, clearingFirst: Bool) throws -> ProjectionResult {
        try database.inTransaction {
            if clearingFirst {
                for type in self.typesByIdentifier.values {
                    try self.database.execute(statement: "DELETE FROM \(type.tableName)")
                }
            }

            var appliedCount = 0
            var unreadableIds: [Value.ID] = []

            for change in changes {
                switch change {
                case let .insert(value), let .update(value):
                    guard let type = self.projectedType(for: value.id) else { continue }
                    let row: [String: SQLiteValue]
                    do {
                        row = try type.extract(value)
                    } catch {
                        unreadableIds.append(value.id)
                        continue
                    }
                    try self.upsert(row, id: value.id, into: type)
                    appliedCount += 1
                case let .remove(valueId):
                    guard let type = self.projectedType(for: valueId) else { continue }
                    try self.database.execute(
                        statement: "DELETE FROM \(type.tableName) WHERE llvs_id = ?",
                        withBindingsList: [[valueId.rawValue]])
                    appliedCount += 1
                case .preserve, .preserveRemoval:
                    // These say a value was carried through a merge unchanged, which leaves
                    // the projected row as it already is.
                    continue
                }
            }

            // Written in the same transaction as the rows above, so the marker can never claim
            // a version whose rows did not land.
            try self.database.execute(
                statement: """
                    INSERT INTO projection_state (id, version_id, schema_version) VALUES (0, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET version_id = excluded.version_id, schema_version = excluded.schema_version
                    """,
                withBindingsList: [[version.rawValue, Int64(self.schemaVersion)]])

            return ProjectionResult(appliedCount: appliedCount, unreadableIds: unreadableIds)
        }
    }

    /// Value IDs are `"<instance>/<TypeName>"`, so the type is the part after the last slash.
    /// This mirrors `LLVSModel.modelTypeIdentifier(from:)` without depending on that library,
    /// which would drag the macro and its SwiftSyntax dependency in for one line of parsing.
    private func projectedType(for valueId: Value.ID) -> ProjectedType? {
        guard let slashIndex = valueId.rawValue.lastIndex(of: "/") else { return nil }
        let typeIdentifier = String(valueId.rawValue[valueId.rawValue.index(after: slashIndex)...])
        return typesByIdentifier[typeIdentifier]
    }

    private func upsert(_ row: [String: SQLiteValue], id: Value.ID, into type: ProjectedType) throws {
        let columnNames = ["llvs_id"] + type.columns.map(\.name)
        let placeholders = Array(repeating: "?", count: columnNames.count).joined(separator: ", ")
        let bindings: [Any?] = [id.rawValue] + type.columns.map { binding(for: row[$0.name] ?? .null) }

        // A table with no columns beyond the identifier has nothing to update on conflict,
        // and SQLite rejects an empty SET clause.
        let conflictClause: String
        if type.columns.isEmpty {
            conflictClause = "ON CONFLICT(llvs_id) DO NOTHING"
        } else {
            let assignments = type.columns.map { "\($0.name) = excluded.\($0.name)" }.joined(separator: ", ")
            conflictClause = "ON CONFLICT(llvs_id) DO UPDATE SET \(assignments)"
        }

        try database.execute(
            statement: """
                INSERT INTO \(type.tableName) (\(columnNames.joined(separator: ", "))) VALUES (\(placeholders))
                \(conflictClause)
                """,
            withBindingsList: [bindings])
    }

    private func binding(for value: SQLiteValue) -> Any? {
        switch value {
        case let .text(string): return string
        case let .integer(integer): return integer
        case let .real(double): return double
        case .null: return nil
        }
    }
}
