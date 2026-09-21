//
//  OwnedTableApplyTests.swift
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

@Suite class OwnedTableApplyTests {

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
                ModelColumn(propertyName: "title", columnName: "title", declaration: "TEXT", storage: .scalar),
                ModelColumn(propertyName: "body", columnName: "body", declaration: "TEXT", storage: .scalar),
            ]))
        for statement in table.createStatements() {
            try database.execute(statement: statement)
        }
    }

    deinit {
        try? database.close()
        try? FileManager.default.removeItem(at: databaseURL)
    }

    private func value(_ id: String, _ object: [String: Any]) throws -> Value {
        Value(id: .init(id), data: try JSONSerialization.data(withJSONObject: object))
    }

    private func title(of id: String) throws -> String? {
        var result: String?
        try database.forEach(matchingQuery: "SELECT title FROM notes WHERE llvs_id = ?", withBindings: [id]) { row in
            result = row.value(inColumnAtIndex: 0)
        }
        return result
    }

    @Test func anInsertedValueBecomesARow() throws {
        let applied = try table.apply([.insert(try value("n1/Note", ["title": "From elsewhere", "body": "b"]))],
            in: database)

        #expect(applied == 1)
        #expect(try title(of: "n1/Note") == "From elsewhere")
    }

    @Test func anUpdatedValueReplacesTheRow() throws {
        try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
            withBindingsList: [["n1/Note", "Old", "b"]])
        try table.clearChangelog(in: database)

        _ = try table.apply([.update(try value("n1/Note", ["title": "New", "body": "b"]))], in: database)

        #expect(try title(of: "n1/Note") == "New")
    }

    @Test func aRemovedValueDeletesTheRow() throws {
        try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
            withBindingsList: [["n1/Note", "Old", "b"]])
        try table.clearChangelog(in: database)

        _ = try table.apply([.remove(.init("n1/Note"))], in: database)

        #expect(try title(of: "n1/Note") == nil)
    }

    /// The whole point of suppression: an applied change must not look like a local edit,
    /// or it would be drained straight back out and the devices would trade it forever.
    @Test func applyingRecordsNoLocalChange() throws {
        _ = try table.apply([.insert(try value("n1/Note", ["title": "From elsewhere", "body": "b"]))],
            in: database)

        #expect(try table.changelogEntries(in: database).isEmpty)
    }

    @Test func localWritesAreCapturedAgainAfterApplying() throws {
        _ = try table.apply([.insert(try value("n1/Note", ["title": "Remote", "body": "b"]))], in: database)

        try database.execute(statement: "UPDATE notes SET title = ? WHERE llvs_id = ?",
            withBindingsList: [["Local", "n1/Note"]])

        #expect(try table.changelogEntries(in: database).count == 1)
    }

    @Test func aValueMissingAPropertyLeavesThatColumnNull() throws {
        _ = try table.apply([.insert(try value("n1/Note", ["title": "Only a title"]))], in: database)

        var body: String? = "unset"
        try database.forEach(matchingQuery: "SELECT body FROM notes WHERE llvs_id = 'n1/Note'") { row in
            body = row.value(inColumnAtIndex: 0)
        }
        #expect(body == nil)
    }

    @Test func aValueThatIsNotJSONIsSkipped() throws {
        let applied = try table.apply([.insert(Value(id: .init("n1/Note"), data: Data("not json".utf8)))],
            in: database)

        // Skipped rather than throwing: one value this build cannot read must not stop the rest.
        #expect(applied == 0)
        #expect(try title(of: "n1/Note") == nil)
    }

    @Test func oneUnreadableValueDoesNotStopTheOthers() throws {
        let changes: [Value.Change] = [
            .insert(Value(id: .init("bad/Note"), data: Data("not json".utf8))),
            .insert(try value("good/Note", ["title": "Fine", "body": "b"])),
        ]

        let applied = try table.apply(changes, in: database)

        #expect(applied == 1)
        #expect(try title(of: "good/Note") == "Fine")
    }

    @Test func preserveChangesAreIgnored() throws {
        try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
            withBindingsList: [["n1/Note", "Kept", "b"]])
        try table.clearChangelog(in: database)

        let applied = try table.apply([.preserveRemoval(.init("other/Note"))], in: database)

        #expect(applied == 0)
        #expect(try title(of: "n1/Note") == "Kept")
    }

    /// A round trip through the two halves: what a drain writes, an apply must read back.
    @Test func applyReadsBackWhatDrainWrote() throws {
        let object: [String: Any] = ["title": "Round trip", "body": "intact"]
        _ = try table.apply([.insert(try value("n1/Note", object))], in: database)

        var title: String?
        var body: String?
        try database.forEach(matchingQuery: "SELECT title, body FROM notes WHERE llvs_id = 'n1/Note'") { row in
            title = row.value(inColumnAtIndex: 0)
            body = row.value(inColumnAtIndex: 1)
        }
        #expect(title == "Round trip")
        #expect(body == "intact")
    }
}
