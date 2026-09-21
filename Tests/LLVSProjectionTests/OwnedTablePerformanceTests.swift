//
//  OwnedTablePerformanceTests.swift
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

/// A drain reads one row per touched value, so its cost should follow what changed rather
/// than how much is in the table. An app saves constantly, so this is on the write path and
/// a regression to per-table cost would be felt immediately.
///
/// Measured when written: a one-row drain took 1.85 ms against 100 rows and 2.50 ms against
/// 5000. The assertion is on the shape, not those numbers, so it does not fail on a slower
/// machine.
@Suite class OwnedTablePerformanceTests {

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

    private var head: Version.ID?

    /// Grows the table to `size` rows and drains them, then returns the cost of draining a
    /// single changed row against a table that size.
    private func millisecondsPerOneRowDrain(atTableSize size: Int) throws -> Double {
        var current = 0
        try database.forEach(matchingQuery: "SELECT COUNT(*) FROM notes") { row in
            current = Int(row.value(inColumnAtIndex: 0) as Int64? ?? 0)
        }
        for index in current..<size {
            try database.execute(statement: "INSERT INTO notes (llvs_id, title) VALUES (?, ?)",
                withBindingsList: [["\(UUID().uuidString)/Note", "note \(index)"]])
        }
        head = try table.drain(in: database, store: store, basedOn: head).version

        var oneId: String?
        try database.forEach(matchingQuery: "SELECT llvs_id FROM notes LIMIT 1") { row in
            oneId = row.value(inColumnAtIndex: 0)
        }
        let identifier = try #require(oneId)

        let iterations = 20
        let start = Date()
        for iteration in 0..<iterations {
            try database.execute(statement: "UPDATE notes SET title = ? WHERE llvs_id = ?",
                withBindingsList: [["edit \(iteration)", identifier]])
            head = try table.drain(in: database, store: store, basedOn: head).version
        }
        return Date().timeIntervalSince(start) * 1000 / Double(iterations)
    }

    @Test func drainCostDoesNotGrowWithTableSize() throws {
        let small = try millisecondsPerOneRowDrain(atTableSize: 100)
        let large = try millisecondsPerOneRowDrain(atTableSize: 5000)

        // Fifty times the rows. A cost that followed table size would show as roughly fifty
        // times the time; the bound is loose enough to absorb noise on a loaded machine.
        #expect(large < small * 5,
            "drain cost is following table size: \(small) ms at 100 rows, \(large) ms at 5000")
    }
}
