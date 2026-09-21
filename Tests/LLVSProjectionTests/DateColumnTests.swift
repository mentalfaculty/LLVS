//
//  DateColumnTests.swift
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
struct DatedNote: StorableModel, Codable, Equatable {
    static let modelTypeIdentifier = "DatedNote"
    var title: String = ""
    var updatedAt: Date = .init(timeIntervalSince1970: 0)
}

/// A `Date` column holds Unix seconds, not the seconds-since-2001 that `Codable` encodes.
///
/// The design promises ordinary SQL, and every SQLite tool — `strftime('%s')`, a database
/// browser, another app sharing the file — means Unix seconds by a timestamp. Storing
/// Codable's number would make the obvious query silently 31 years wrong, which is the
/// worst kind of bug: no error, just the wrong answer.
@Suite class DateColumnTests {

    let database: SQLiteDatabase
    let databaseURL: URL
    let table: OwnedTable

    /// 2025-09-20 20:26:40 UTC, as Unix seconds.
    let unixSeconds: Int64 = 1758400000

    init() throws {
        databaseURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".sqlite")
        database = try SQLiteDatabase(fileURL: databaseURL)
        table = OwnedTable(
            typeIdentifier: DatedNote.modelTypeIdentifier,
            tableName: "notes",
            schema: DatedNote.sqliteSchema)
        for statement in table.createStatements() {
            try database.execute(statement: statement)
        }
    }

    deinit {
        try? database.close()
        try? FileManager.default.removeItem(at: databaseURL)
    }

    @Test func aDatePropertyGetsADateColumn() {
        let column = DatedNote.sqliteSchema.columns.first { $0.propertyName == "updatedAt" }
        #expect(column?.storage == .date)
        #expect(column?.declaration == "INTEGER")
    }

    /// The case the design promises: an app writes a Unix timestamp with plain SQL, the way
    /// it would against any SQLite table, and the model reads the date it meant.
    @Test func aUnixTimestampWrittenInSQLReadsBackAsThatDate() throws {
        try database.execute(statement: "INSERT INTO notes (llvs_id, title, updated_at) VALUES (?, ?, ?)",
            withBindingsList: [["n1/DatedNote", "Hello", unixSeconds]])

        let rows = try table.fetch(DatedNote.self, in: database)

        #expect(rows.first?.model.updatedAt.timeIntervalSince1970 == TimeInterval(unixSeconds))
    }

    /// And the reverse: a date applied from LLVS lands in the column as Unix seconds, so a
    /// query written against it means what it says.
    @Test func anAppliedDateIsStoredAsUnixSeconds() throws {
        let note = DatedNote(title: "Hello", updatedAt: Date(timeIntervalSince1970: TimeInterval(unixSeconds)))
        let data = try JSONEncoder().encode(note)

        try table.apply([.insert(Value(id: .init("n1/DatedNote"), data: data))], in: database)

        var stored: Int64?
        try database.forEach(matchingQuery: "SELECT updated_at FROM notes") { row in
            stored = row.value(inColumnAtIndex: 0)
        }
        #expect(stored == unixSeconds)
    }

    @Test func aDateSurvivesTheWholeWayRound() throws {
        let note = DatedNote(title: "Hello", updatedAt: Date(timeIntervalSince1970: TimeInterval(unixSeconds)))
        let data = try JSONEncoder().encode(note)
        try table.apply([.insert(Value(id: .init("n1/DatedNote"), data: data))], in: database)

        let rows = try table.fetch(DatedNote.self, in: database)

        #expect(rows.first?.model == note)
    }

    /// SQLite's own time functions must agree with the column, or a query like
    /// `WHERE updated_at > strftime('%s', 'now', '-7 days')` would quietly select nothing.
    @Test func sqliteTimeFunctionsAgreeWithTheColumn() throws {
        let now = Date()
        let note = DatedNote(title: "Recent", updatedAt: now)
        try table.apply([.insert(Value(id: .init("n1/DatedNote"), data: try JSONEncoder().encode(note)))],
            in: database)

        var matched = 0
        try database.forEach(matchingQuery: """
            SELECT llvs_id FROM notes WHERE updated_at > strftime('%s', 'now', '-1 day')
            """) { _ in matched += 1 }

        #expect(matched == 1)
    }

    @Test func aDrainedDateIsReadBackCorrectly() throws {
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = try Store(rootDirectoryURL: rootURL)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try database.execute(statement: "INSERT INTO notes (llvs_id, title, updated_at) VALUES (?, ?, ?)",
            withBindingsList: [["n1/DatedNote", "Hello", unixSeconds]])

        let result = try table.drain(in: database, store: store, basedOn: nil)

        let versionId = try #require(result.version)
        let value = try #require(try store.value(id: .init("n1/DatedNote"), at: versionId))
        let decoded = try JSONDecoder().decode(DatedNote.self, from: value.data)
        #expect(decoded.updatedAt.timeIntervalSince1970 == TimeInterval(unixSeconds))
    }
}
