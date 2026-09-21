//
//  OwnedTableMigrationTests.swift
//  LLVSProjectionTests
//
//  Created by Drew McCormack on 21/09/2026.
//

import Testing
import Foundation
@testable import LLVS
@testable import LLVSSQLite
@testable import LLVSModel
@testable import LLVSProjection

/// Rebuilding discards a table, so anything the app wrote that has not reached LLVS must be
/// drained first or it is lost. The order is the whole rule.
@Suite class OwnedTableMigrationTests {

    let store: Store
    let database: SQLiteDatabase
    let rootURL: URL
    let databaseURL: URL
    let table: OwnedTable

    init() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store = try Store(rootDirectoryURL: rootURL)
        databaseURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".sqlite")
        database = try SQLiteDatabase(fileURL: databaseURL)
        table = OwnedTable(
            typeIdentifier: "Note",
            tableName: "notes",
            schema: ModelSchema(columns: [
                ModelColumn(propertyName: "title", columnName: "title", storage: .text),
            ]))
        for statement in table.createStatements() {
            try database.execute(statement: statement)
        }
    }

    deinit {
        try? database.close()
        try? FileManager.default.removeItem(at: databaseURL)
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func makeProjector(registering table: OwnedTable?) throws -> Projector {
        let projector = try Projector(database: database, store: store, types: [], schemaVersion: 1)
        if let table { projector.registerOwnedTable(table) }
        return projector
    }

    @Test func aRebuildDrainsPendingLocalEditsFirst() throws {
        try database.execute(statement: "INSERT INTO notes (llvs_id, title) VALUES (?, ?)",
            withBindingsList: [["n1/Note", "Unsynced"]])
        // Never drained: this edit exists only in SQLite.

        let projector = try makeProjector(registering: table)
        let version = try projector.drainOwnedTables(store: store, basedOn: nil)

        let versionId = try #require(version)
        #expect(try store.value(id: .init("n1/Note"), at: versionId) != nil)
    }

    @Test func aFailedDrainStopsBeforeAnythingIsDiscarded() throws {
        try database.execute(statement: "INSERT INTO notes (llvs_id, title) VALUES (?, ?)",
            withBindingsList: [["n1/Note", "Unsynced"]])

        // Make the drain fail by removing the table it reads the row from.
        try database.execute(statement: "DROP TABLE notes")

        let projector = try makeProjector(registering: table)
        #expect(throws: (any Swift.Error).self) {
            _ = try projector.drainOwnedTables(store: self.store, basedOn: nil)
        }
    }

    @Test func drainingWithNothingPendingKeepsTheVersion() throws {
        let existing = try store.makeVersion(basedOnPredecessor: nil,
            inserting: [Value(id: .init("seed"), data: Data("s".utf8))])

        let projector = try makeProjector(registering: table)
        let version = try projector.drainOwnedTables(store: store, basedOn: existing.id)

        #expect(version == existing.id)
    }

    @Test func severalOwnedTablesDrainInSequence() throws {
        let second = OwnedTable(
            typeIdentifier: "Tag",
            tableName: "tags",
            schema: ModelSchema(columns: [
                ModelColumn(propertyName: "label", columnName: "label", storage: .text),
            ]))
        for statement in second.createStatements() { try database.execute(statement: statement) }

        try database.execute(statement: "INSERT INTO notes (llvs_id, title) VALUES (?, ?)",
            withBindingsList: [["n1/Note", "A note"]])
        try database.execute(statement: "INSERT INTO tags (llvs_id, label) VALUES (?, ?)",
            withBindingsList: [["t1/Tag", "A tag"]])

        let projector = try makeProjector(registering: table)
        projector.registerOwnedTable(second)
        let version = try #require(try projector.drainOwnedTables(store: store, basedOn: nil))

        // The second drain built on the first, so both rows are present at the final version.
        #expect(try store.value(id: .init("n1/Note"), at: version) != nil)
        #expect(try store.value(id: .init("t1/Tag"), at: version) != nil)
    }

    @Test func aProjectorWithNoOwnedTablesIsUnaffected() throws {
        let projector = try makeProjector(registering: nil)
        #expect(try projector.drainOwnedTables(store: store, basedOn: nil) == nil)
    }
}
