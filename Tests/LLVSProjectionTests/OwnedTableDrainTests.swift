//
//  OwnedTableDrainTests.swift
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

@Suite class OwnedTableDrainTests {

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
                ModelColumn(propertyName: "body", columnName: "body", storage: .text),
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

    private func insertNote(_ id: String, title: String, body: String) throws {
        try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
            withBindingsList: [[id, title, body]])
    }

    private func json(of id: String, at version: Version.ID) throws -> [String: Any] {
        let value = try #require(try store.value(id: .init(id), at: version))
        return try #require(try JSONSerialization.jsonObject(with: value.data) as? [String: Any])
    }

    @Test func anInsertBecomesAVersionHoldingTheRow() throws {
        try insertNote("n1/Note", title: "Hello", body: "Body")

        let result = try table.drain(in: database, store: store, basedOn: nil)

        let versionId = try #require(result.version)
        let object = try json(of: "n1/Note", at: versionId)
        #expect(object["title"] as? String == "Hello")
        #expect(object["body"] as? String == "Body")
    }

    /// The stored JSON is keyed by property name, because that is what the model decodes
    /// from. The column name is SQLite's business and stops at the table.
    @Test func theValueIsKeyedByPropertyName() throws {
        let other = OwnedTable(
            typeIdentifier: "Note",
            tableName: "notes2",
            schema: ModelSchema(columns: [
                ModelColumn(propertyName: "updatedAt", columnName: "updated_at", storage: .integer),
            ]))
        for statement in other.createStatements() { try database.execute(statement: statement) }
        try database.execute(statement: "INSERT INTO notes2 (llvs_id, updated_at) VALUES (?, ?)",
            withBindingsList: [["n9/Note", Int64(1758400000)]])

        let result = try other.drain(in: database, store: store, basedOn: nil)

        let versionId = try #require(result.version)
        let object = try json(of: "n9/Note", at: versionId)
        #expect(object["updatedAt"] != nil)
        #expect(object["updated_at"] == nil)
    }

    @Test func aDeleteBecomesARemoval() throws {
        try insertNote("n1/Note", title: "Hello", body: "Body")
        let first = try table.drain(in: database, store: store, basedOn: nil)

        try database.execute(statement: "DELETE FROM notes WHERE llvs_id = ?", withBindingsList: [["n1/Note"]])
        let second = try table.drain(in: database, store: store, basedOn: first.version)

        let versionId = try #require(second.version)
        #expect(try store.value(id: .init("n1/Note"), at: versionId) == nil)
    }

    @Test func severalEditsToOneRowBecomeOneChange() throws {
        try insertNote("n1/Note", title: "Hello", body: "Body")
        let first = try table.drain(in: database, store: store, basedOn: nil)

        try database.execute(statement: "UPDATE notes SET title = ? WHERE llvs_id = ?",
            withBindingsList: [["One", "n1/Note"]])
        try database.execute(statement: "UPDATE notes SET body = ? WHERE llvs_id = ?",
            withBindingsList: [["Two", "n1/Note"]])
        let second = try table.drain(in: database, store: store, basedOn: first.version)

        // Two captured entries, one row, so one change carrying the row as it now stands.
        #expect(second.changeCount == 1)
        let versionId = try #require(second.version)
        let object = try json(of: "n1/Note", at: versionId)
        #expect(object["title"] as? String == "One")
        #expect(object["body"] as? String == "Two")
    }

    @Test func drainingNothingMakesNoVersion() throws {
        let result = try table.drain(in: database, store: store, basedOn: nil)
        #expect(result.version == nil)
        #expect(result.changeCount == 0)
    }

    @Test func drainingClearsWhatItTook() throws {
        try insertNote("n1/Note", title: "Hello", body: "Body")
        _ = try table.drain(in: database, store: store, basedOn: nil)
        #expect(try table.changelogEntries(in: database).isEmpty)
    }

    /// A row created and deleted between two drains never reached LLVS, so it must not
    /// arrive as a removal of something that was never there.
    @Test func aRowCreatedAndDeletedBeforeDrainingIsNotReported() throws {
        try insertNote("n1/Note", title: "Hello", body: "Body")
        try database.execute(statement: "DELETE FROM notes WHERE llvs_id = ?", withBindingsList: [["n1/Note"]])

        let result = try table.drain(in: database, store: store, basedOn: nil)

        #expect(result.changeCount == 0)
        #expect(try table.changelogEntries(in: database).isEmpty)
    }

    @Test func aSecondDrainBuildsOnTheFirst() throws {
        try insertNote("n1/Note", title: "First", body: "a")
        let first = try table.drain(in: database, store: store, basedOn: nil)

        try insertNote("n2/Note", title: "Second", body: "b")
        let second = try table.drain(in: database, store: store, basedOn: first.version)

        let versionId = try #require(second.version)
        // Both rows are present at the later version, so it descends from the first.
        #expect(try store.value(id: .init("n1/Note"), at: versionId) != nil)
        #expect(try store.value(id: .init("n2/Note"), at: versionId) != nil)
    }

    @Test func anUpdateToAnExistingRowIsAnUpdateNotAnInsert() throws {
        try insertNote("n1/Note", title: "Before", body: "a")
        let first = try table.drain(in: database, store: store, basedOn: nil)

        try database.execute(statement: "UPDATE notes SET title = ? WHERE llvs_id = ?",
            withBindingsList: [["After", "n1/Note"]])
        let second = try table.drain(in: database, store: store, basedOn: first.version)

        let versionId = try #require(second.version)
        let object = try json(of: "n1/Note", at: versionId)
        #expect(object["title"] as? String == "After")
    }

    @Test func nullColumnsAreOmittedFromTheValue() throws {
        try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, NULL)",
            withBindingsList: [["n1/Note", "Only a title"]])

        let result = try table.drain(in: database, store: store, basedOn: nil)

        let versionId = try #require(result.version)
        let object = try json(of: "n1/Note", at: versionId)
        #expect(object["title"] as? String == "Only a title")
        // An absent property decodes as nil for an optional, which a null would not.
        #expect(object["body"] == nil)
    }

    /// A row deleted and reinserted between drains has `.insert` as its last operation but
    /// still exists in the store, so it must go out as an update or the insert fails. This is
    /// why the drain asks the store what exists rather than inferring it from the changelog.
    @Test func aRowDeletedAndReinsertedBecomesAnUpdate() throws {
        try insertNote("n1/Note", title: "First", body: "a")
        let first = try table.drain(in: database, store: store, basedOn: nil)

        try database.execute(statement: "DELETE FROM notes WHERE llvs_id = ?", withBindingsList: [["n1/Note"]])
        try insertNote("n1/Note", title: "Reborn", body: "b")
        let second = try table.drain(in: database, store: store, basedOn: first.version)

        let versionId = try #require(second.version)
        let object = try json(of: "n1/Note", at: versionId)
        #expect(object["title"] as? String == "Reborn")
    }

    @Test func aRowUpdatedThenDeletedThenReinsertedTakesItsFinalState() throws {
        try insertNote("n1/Note", title: "First", body: "a")
        let first = try table.drain(in: database, store: store, basedOn: nil)

        try database.execute(statement: "UPDATE notes SET title = ? WHERE llvs_id = ?",
            withBindingsList: [["Middle", "n1/Note"]])
        try database.execute(statement: "DELETE FROM notes WHERE llvs_id = ?", withBindingsList: [["n1/Note"]])
        try insertNote("n1/Note", title: "Final", body: "c")
        let second = try table.drain(in: database, store: store, basedOn: first.version)

        let versionId = try #require(second.version)
        let object = try json(of: "n1/Note", at: versionId)
        #expect(object["title"] as? String == "Final")
    }

    /// The reverse: inserted then deleted within one window, for a row the store already has.
    @Test func aRowUpdatedThenDeletedBecomesARemoval() throws {
        try insertNote("n1/Note", title: "First", body: "a")
        let first = try table.drain(in: database, store: store, basedOn: nil)

        try database.execute(statement: "UPDATE notes SET title = ? WHERE llvs_id = ?",
            withBindingsList: [["Edited", "n1/Note"]])
        try database.execute(statement: "DELETE FROM notes WHERE llvs_id = ?", withBindingsList: [["n1/Note"]])
        let second = try table.drain(in: database, store: store, basedOn: first.version)

        let versionId = try #require(second.version)
        #expect(try store.value(id: .init("n1/Note"), at: versionId) == nil)
    }
}
