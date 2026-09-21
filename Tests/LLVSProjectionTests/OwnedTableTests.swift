//
//  OwnedTableTests.swift
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

@Suite class OwnedTableTests {

    let database: SQLiteDatabase
    let databaseURL: URL
    let table: OwnedTable

    init() throws {
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
    }

    private func entries() throws -> [ChangelogEntry] {
        try table.changelogEntries(in: database)
    }

    private func title(of id: String) throws -> String? {
        var result: String?
        try database.forEach(matchingQuery: "SELECT title FROM notes WHERE llvs_id = ?", withBindings: [id]) { row in
            result = row.value(inColumnAtIndex: 0)
        }
        return result
    }

    @Test func anInsertIsCaptured() throws {
        try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
            withBindingsList: [["n1", "Hello", "Body"]])

        let captured = try entries()
        #expect(captured.count == 1)
        #expect(captured.first?.valueId.rawValue == "n1")
        #expect(captured.first?.operation == .insert)
    }

    /// The point of per-column capture: an update names the column that changed, which is
    /// what lets two devices editing different columns merge without losing either edit.
    @Test func anUpdateIsCapturedPerChangedColumn() throws {
        try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
            withBindingsList: [["n1", "Hello", "Body"]])
        try table.clearChangelog(in: database)

        try database.execute(statement: "UPDATE notes SET title = ? WHERE llvs_id = ?",
            withBindingsList: [["Changed", "n1"]])

        let captured = try entries()
        #expect(captured.count == 1)
        #expect(captured.first?.columnName == "title")
        #expect(captured.first?.operation == .update)
    }

    @Test func changingTwoColumnsCapturesBoth() throws {
        try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
            withBindingsList: [["n1", "Hello", "Body"]])
        try table.clearChangelog(in: database)

        try database.execute(statement: "UPDATE notes SET title = ?, body = ? WHERE llvs_id = ?",
            withBindingsList: [["New title", "New body", "n1"]])

        #expect(Set(try entries().compactMap(\.columnName)) == ["title", "body"])
    }

    @Test func anUpdateThatChangesNothingIsNotCaptured() throws {
        try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
            withBindingsList: [["n1", "Hello", "Body"]])
        try table.clearChangelog(in: database)

        try database.execute(statement: "UPDATE notes SET title = title WHERE llvs_id = ?",
            withBindingsList: [["n1"]])

        #expect(try entries().isEmpty)
    }

    /// One SQL statement touching many rows must yield one entry per row, or a bulk edit
    /// would collapse into a single change and lose the others.
    @Test func aMultiRowUpdateIsCapturedPerRow() throws {
        try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
            withBindingsList: [["n1", "A", "x"], ["n2", "B", "y"]])
        try table.clearChangelog(in: database)

        try database.execute(statement: "UPDATE notes SET title = title || '!'")

        let captured = try entries()
        #expect(captured.count == 2)
        #expect(Set(captured.map(\.valueId.rawValue)) == ["n1", "n2"])
    }

    @Test func aDeleteIsCaptured() throws {
        try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
            withBindingsList: [["n1", "Hello", "Body"]])
        try table.clearChangelog(in: database)

        try database.execute(statement: "DELETE FROM notes WHERE llvs_id = ?", withBindingsList: [["n1"]])

        let captured = try entries()
        #expect(captured.count == 1)
        #expect(captured.first?.operation == .remove)
        #expect(captured.first?.valueId.rawValue == "n1")
    }

    /// Applying a version from another device must not look like a local edit, or the change
    /// would be sent straight back out and the two devices would trade it forever.
    @Test func aWriteUnderSuppressionIsNotCaptured() throws {
        try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
            withBindingsList: [["n1", "Hello", "Body"]])
        try table.clearChangelog(in: database)

        try table.whileApplyingRemoteChanges(in: database) {
            try self.database.execute(statement: "UPDATE notes SET title = ? WHERE llvs_id = ?",
                withBindingsList: [["From another device", "n1"]])
        }

        #expect(try entries().isEmpty)
        // The row really did change; only the capture was suppressed.
        #expect(try title(of: "n1") == "From another device")
    }

    @Test func suppressionIsLiftedAfterTheBlock() throws {
        try table.whileApplyingRemoteChanges(in: database) {
            try self.database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
                withBindingsList: [["n1", "Remote", "x"]])
        }
        try database.execute(statement: "UPDATE notes SET title = ? WHERE llvs_id = ?",
            withBindingsList: [["Local", "n1"]])

        #expect(try entries().count == 1)
    }

    @Test func suppressionIsLiftedEvenWhenTheBlockThrows() throws {
        struct Boom: Swift.Error {}
        #expect(throws: Boom.self) {
            try self.table.whileApplyingRemoteChanges(in: self.database) { throw Boom() }
        }

        try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
            withBindingsList: [["n1", "Local", "x"]])
        #expect(try entries().count == 1)
    }

    /// Triggers fire inside the app's transaction, so a rollback takes the changelog with it.
    /// This is what makes an app's own BEGIN/COMMIT the version boundary with no mechanism.
    @Test func aRolledBackWriteLeavesNoEntry() throws {
        try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
            withBindingsList: [["n1", "Hello", "Body"]])
        try table.clearChangelog(in: database)

        struct Boom: Swift.Error {}
        #expect(throws: Boom.self) {
            try self.database.inTransaction {
                try self.database.execute(statement: "UPDATE notes SET title = ? WHERE llvs_id = ?",
                    withBindingsList: [["Doomed", "n1"]])
                throw Boom()
            }
        }

        #expect(try entries().isEmpty)
        #expect(try title(of: "n1") == "Hello")
    }

    @Test func clearingThroughASequenceKeepsLaterEntries() throws {
        try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
            withBindingsList: [["n1", "A", "x"]])
        let first = try #require(try entries().first)

        try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
            withBindingsList: [["n2", "B", "y"]])

        try table.clearChangelog(in: database, throughSequence: first.sequence)

        let remaining = try entries()
        #expect(remaining.count == 1)
        #expect(remaining.first?.valueId.rawValue == "n2")
    }
}
