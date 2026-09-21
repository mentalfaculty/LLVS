//
//  JSONFragmentTests.swift
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

typealias AliasedTitle = String

/// A macro cannot resolve a typealias, so `title` gets a JSON column rather than TEXT. That
/// is reported in `propertiesStoredAsJSON`, and it must also *work*.
@MergeableModel
struct AliasedNote: StorableModel, Codable, Equatable {
    static let modelTypeIdentifier = "AliasedNote"
    var title: AliasedTitle = ""
    var body: String = ""
}

/// A JSON column can hold a scalar, not only an array or a dictionary.
///
/// `JSONSerialization.data(withJSONObject:)` raises an Objective-C exception for a top-level
/// value that is not a collection. That is not a Swift error: `try?` cannot catch it and the
/// process dies. A scalar reaches a JSON column whenever a property's type could not be
/// resolved — a typealias, or a raw-value enum — and the value can arrive from another
/// device, so this was a sync-time crash on a device that had done nothing wrong.
@Suite class JSONFragmentTests {

    let database: SQLiteDatabase
    let databaseURL: URL
    let table: OwnedTable

    init() throws {
        databaseURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".sqlite")
        database = try SQLiteDatabase(fileURL: databaseURL)
        table = OwnedTable(
            typeIdentifier: AliasedNote.modelTypeIdentifier,
            tableName: "notes",
            schema: AliasedNote.sqliteSchema)
        for statement in table.createStatements() {
            try database.execute(statement: statement)
        }
    }

    deinit {
        try? database.close()
        try? FileManager.default.removeItem(at: databaseURL)
    }

    @Test func anAliasedPropertyIsAJSONColumnAndIsReported() {
        let byProperty = Dictionary(uniqueKeysWithValues: AliasedNote.sqliteSchema.columns.map { ($0.propertyName, $0.storage) })
        #expect(byProperty["title"] == .json)
        #expect(byProperty["body"] == .text)
        #expect(AliasedNote.sqliteSchema.propertiesStoredAsJSON == ["title": "AliasedTitle"])
    }

    /// Before the fix this killed the test process rather than failing.
    @Test func applyingAScalarIntoAJSONColumnDoesNotCrash() throws {
        let note = AliasedNote(title: "hello", body: "b")
        let data = try JSONEncoder().encode(note)

        try table.apply([.insert(Value(id: .init("n1/AliasedNote"), data: data))], in: database)

        var stored: String?
        try database.forEach(matchingQuery: "SELECT title FROM notes") { row in
            stored = row.value(inColumnAtIndex: 0)
        }
        #expect(stored == "\"hello\"")
    }

    @Test func aScalarInAJSONColumnReadsBackAsTheModel() throws {
        let note = AliasedNote(title: "hello", body: "b")
        try table.apply([.insert(Value(id: .init("n1/AliasedNote"), data: try JSONEncoder().encode(note)))],
            in: database)

        let rows = try table.fetch(AliasedNote.self, in: database)

        #expect(rows.first?.model == note)
    }

    @Test func aScalarInAJSONColumnSurvivesADrain() throws {
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = try Store(rootDirectoryURL: rootURL)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let note = AliasedNote(title: "hello", body: "b")
        try table.apply([.insert(Value(id: .init("n1/AliasedNote"), data: try JSONEncoder().encode(note)))],
            in: database)
        // Make it look like a local edit so there is something to drain.
        try database.execute(statement: "UPDATE notes SET body = ? WHERE llvs_id = ?",
            withBindingsList: [["edited", "n1/AliasedNote"]])

        let result = try table.drain(in: database, store: store, basedOn: nil)

        let versionId = try #require(result.version)
        let value = try #require(try store.value(id: .init("n1/AliasedNote"), at: versionId))
        let decoded = try JSONDecoder().decode(AliasedNote.self, from: value.data)
        #expect(decoded.title == "hello")
        #expect(decoded.body == "edited")
    }

    /// A number and a bool are scalars too, and reach a JSON column the same way.
    @Test func otherScalarsInAJSONColumnAlsoSurvive() throws {
        let type = OwnedTable(
            typeIdentifier: "Odd",
            tableName: "odds",
            schema: ModelSchema(columns: [
                ModelColumn(propertyName: "number", columnName: "number", storage: .json),
                ModelColumn(propertyName: "flag", columnName: "flag", storage: .json),
            ]))
        for statement in type.createStatements() { try database.execute(statement: statement) }

        let data = try JSONSerialization.data(withJSONObject: ["number": 7, "flag": true])
        try type.apply([.insert(Value(id: .init("o1/Odd"), data: data))], in: database)

        var number: String?
        var flag: String?
        try database.forEach(matchingQuery: "SELECT number, flag FROM odds") { row in
            number = row.value(inColumnAtIndex: 0)
            flag = row.value(inColumnAtIndex: 1)
        }
        #expect(number == "7")
        #expect(flag == "true")
    }
}
