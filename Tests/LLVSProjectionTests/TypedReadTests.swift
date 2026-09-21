//
//  TypedReadTests.swift
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

@MergeableModel
struct TypedNote: StorableModel, Codable, Equatable {
    static let modelTypeIdentifier = "TypedNote"
    var title: String = ""
    var body: String = ""
    var rank: Int = 0
    var tags: [String] = []
}

@Suite class TypedReadTests {

    let database: SQLiteDatabase
    let databaseURL: URL
    let table: OwnedTable

    init() throws {
        databaseURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".sqlite")
        database = try SQLiteDatabase(fileURL: databaseURL)
        table = OwnedTable(
            typeIdentifier: TypedNote.modelTypeIdentifier,
            tableName: "notes",
            schema: TypedNote.sqliteSchema)
        for statement in table.createStatements() {
            try database.execute(statement: statement)
        }
    }

    deinit {
        try? database.close()
        try? FileManager.default.removeItem(at: databaseURL)
    }

    private func insert(_ id: String, title: String, body: String = "b", rank: Int64 = 0, tags: String = "[]") throws {
        try database.execute(
            statement: "INSERT INTO notes (llvs_id, title, body, rank, tags) VALUES (?, ?, ?, ?, ?)",
            withBindingsList: [[id, title, body, rank, tags]])
    }

    @Test func fetchReturnsModels() throws {
        try insert("n1/TypedNote", title: "Hello", body: "World")

        let rows = try table.fetch(TypedNote.self, in: database)

        #expect(rows.count == 1)
        #expect(rows.first?.model.title == "Hello")
        #expect(rows.first?.model.body == "World")
        #expect(rows.first?.id.rawValue == "n1/TypedNote")
    }

    @Test func fetchAppliesAWhereClause() throws {
        try insert("n1/TypedNote", title: "Keep")
        try insert("n2/TypedNote", title: "Drop")

        let rows = try table.fetch(TypedNote.self, in: database, where: "title = ?", bindings: ["Keep"])

        #expect(rows.count == 1)
        #expect(rows.first?.model.title == "Keep")
    }

    /// The reason for real columns rather than JSON: an ordinary indexed query works.
    @Test func fetchCanQueryAScalarColumn() throws {
        try insert("n1/TypedNote", title: "Low", rank: 1)
        try insert("n2/TypedNote", title: "High", rank: 10)
        try database.execute(statement: "CREATE INDEX notes_rank ON notes(rank)")

        let rows = try table.fetch(TypedNote.self, in: database, where: "rank > ?", bindings: [Int64(5)])

        #expect(rows.count == 1)
        #expect(rows.first?.model.title == "High")
    }

    @Test func aJSONColumnRoundTrips() throws {
        try insert("n1/TypedNote", title: "Tagged", tags: "[\"a\",\"b\"]")

        let rows = try table.fetch(TypedNote.self, in: database)

        #expect(rows.first?.model.tags == ["a", "b"])
    }

    @Test func fetchCarriesTheVersionItWasReadAt() throws {
        try insert("n1/TypedNote", title: "Hello")
        let version = Version.ID("some-version")

        let rows = try table.fetch(TypedNote.self, in: database, atVersion: version)

        #expect(rows.first?.version == version)
    }

    @Test func fetchReturnsNothingForAnEmptyTable() throws {
        #expect(try table.fetch(TypedNote.self, in: database).isEmpty)
    }

    /// A row that cannot be decoded is left out rather than failing the query, so one bad
    /// row does not blank a list view.
    @Test func anUndecodableRowIsSkipped() throws {
        try insert("n1/TypedNote", title: "Fine")
        // A NULL in a non-optional String property cannot decode.
        try database.execute(
            statement: "INSERT INTO notes (llvs_id, title, body, rank, tags) VALUES (?, NULL, ?, ?, ?)",
            withBindingsList: [["n2/TypedNote", "b", Int64(0), "[]"]])

        let rows = try table.fetch(TypedNote.self, in: database)

        #expect(rows.count == 1)
        #expect(rows.first?.model.title == "Fine")
    }

    /// What the drain writes, a typed read must give back as the same model.
    @Test func aModelSurvivesTheWholeWayRound() throws {
        let original = TypedNote(title: "Round", body: "Trip", rank: 7, tags: ["x", "y"])
        let data = try JSONEncoder().encode(original)
        try table.apply([.insert(Value(id: .init("n1/TypedNote"), data: data))], in: database)

        let rows = try table.fetch(TypedNote.self, in: database)

        #expect(rows.first?.model == original)
    }
}
