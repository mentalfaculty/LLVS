//
//  OwnedTableRoundTripTests.swift
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
struct RoundTripNote: StorableModel, Codable, Equatable {
    static let modelTypeIdentifier = "RoundTripNote"
    var title: String = ""
    var body: String = ""
}

/// One device: its own store, its own SQLite, its own owned table.
private final class Device {
    let store: Store
    let database: SQLiteDatabase
    let table: OwnedTable
    let rootURL: URL
    let databaseURL: URL
    var head: Version.ID?

    init() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store = try Store(rootDirectoryURL: rootURL)
        databaseURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".sqlite")
        database = try SQLiteDatabase(fileURL: databaseURL)
        table = OwnedTable(
            typeIdentifier: RoundTripNote.modelTypeIdentifier,
            tableName: "notes",
            schema: RoundTripNote.sqliteSchema)
        for statement in table.createStatements() {
            try database.execute(statement: statement)
        }
    }

    deinit {
        try? database.close()
        try? FileManager.default.removeItem(at: databaseURL)
        try? FileManager.default.removeItem(at: rootURL)
    }

    func execute(_ statement: String, _ bindings: [Any?] = []) throws {
        try database.execute(statement: statement, withBindingsList: [bindings])
    }

    @discardableResult
    func drain() throws -> Version.ID? {
        let result = try table.drain(in: database, store: store, basedOn: head)
        if let version = result.version { head = version }
        return result.version
    }

    func note(_ id: String, at version: Version.ID) throws -> RoundTripNote? {
        guard let value = try store.value(id: .init(id), at: version) else { return nil }
        return try JSONDecoder().decode(RoundTripNote.self, from: value.data)
    }

    func row(_ id: String) throws -> (title: String?, body: String?) {
        var title: String?
        var body: String?
        try database.forEach(matchingQuery: "SELECT title, body FROM notes WHERE llvs_id = ?",
            withBindings: [id]) { row in
            title = row.value(inColumnAtIndex: 0)
            body = row.value(inColumnAtIndex: 1)
        }
        return (title, body)
    }
}

@Suite class OwnedTableRoundTripTests {

    private let deviceA: Device
    private let deviceB: Device

    init() throws {
        deviceA = try Device()
        deviceB = try Device()
    }

    private func arbiter() -> MergeableArbiter {
        let arbiter = MergeableArbiter()
        arbiter.register(RoundTripNote.self)
        return arbiter
    }

    /// Copies every version device A has into device B's store, so B can merge against it.
    /// Stands in for a sync, without needing an exchange for a test about merging.
    private func copyVersions(from source: Device, to destination: Device, upTo version: Version.ID) throws {
        var toCopy: [Version] = []
        try source.store.queryHistory { history in
            for candidate in history {
                toCopy.append(candidate)
            }
        }
        // Oldest first, so a version's predecessor always exists before it does.
        for candidate in toCopy.reversed() {
            guard !destination.store.historyIncludesVersions(identifiedBy: [candidate.id]) else { continue }
            let changes = try source.store.valueChanges(madeInVersionIdentifiedBy: candidate.id)
            try destination.store.addVersion(candidate, storing: changes)
        }
        _ = version
    }

    @Test func aWriteSurvivesTheRoundTrip() throws {
        try deviceA.execute("INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
            ["n1/RoundTripNote", "Hello", "World"])

        let version = try #require(try deviceA.drain())

        let note = try #require(try deviceA.note("n1/RoundTripNote", at: version))
        #expect(note == RoundTripNote(title: "Hello", body: "World"))
    }

    /// The claim the whole design rests on. Two devices edit different columns of one row,
    /// with no coordination, and both edits survive the merge.
    @Test func twoDevicesEditingDifferentColumnsBothKeepTheirEdit() throws {
        // A shared starting point, made on A and copied to B.
        try deviceA.execute("INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
            ["n1/RoundTripNote", "Original", "Original body"])
        let base = try #require(try deviceA.drain())
        try copyVersions(from: deviceA, to: deviceB, upTo: base)
        deviceB.head = base
        try deviceB.table.apply(try deviceA.store.valueChanges(madeInVersionIdentifiedBy: base), in: deviceB.database)

        // A edits only the title.
        try deviceA.execute("UPDATE notes SET title = ? WHERE llvs_id = ?", ["A's title", "n1/RoundTripNote"])
        let versionA = try #require(try deviceA.drain())

        // B, from the same base, edits only the body.
        try deviceB.execute("UPDATE notes SET body = ? WHERE llvs_id = ?", ["B's body", "n1/RoundTripNote"])
        let versionB = try #require(try deviceB.drain())

        // B receives A's version and merges.
        try copyVersions(from: deviceA, to: deviceB, upTo: versionA)
        let merged = try deviceB.store.merge(version: versionB, with: versionA, resolvingWith: arbiter())

        let note = try #require(try deviceB.note("n1/RoundTripNote", at: merged.id))
        #expect(note.title == "A's title")
        #expect(note.body == "B's body")
    }

    /// And the merged result lands back in the table, which is what the user sees.
    @Test func theMergedResultLandsBackInTheTable() throws {
        try deviceA.execute("INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
            ["n1/RoundTripNote", "Original", "Original body"])
        let base = try #require(try deviceA.drain())
        try copyVersions(from: deviceA, to: deviceB, upTo: base)
        deviceB.head = base
        try deviceB.table.apply(try deviceA.store.valueChanges(madeInVersionIdentifiedBy: base), in: deviceB.database)

        try deviceA.execute("UPDATE notes SET title = ? WHERE llvs_id = ?", ["A's title", "n1/RoundTripNote"])
        let versionA = try #require(try deviceA.drain())

        try deviceB.execute("UPDATE notes SET body = ? WHERE llvs_id = ?", ["B's body", "n1/RoundTripNote"])
        let versionB = try #require(try deviceB.drain())

        try copyVersions(from: deviceA, to: deviceB, upTo: versionA)
        let merged = try deviceB.store.merge(version: versionB, with: versionA, resolvingWith: arbiter())

        let changes = try deviceB.store.valueChanges(updatingFrom: versionB, to: merged.id)
        try deviceB.table.apply(changes, in: deviceB.database)

        let row = try deviceB.row("n1/RoundTripNote")
        #expect(row.title == "A's title")
        #expect(row.body == "B's body")
        // And applying it did not look like a local edit.
        #expect(try deviceB.table.changelogEntries(in: deviceB.database).isEmpty)
    }

    /// The spec's stated rule for a delete racing an edit: the row comes back carrying the
    /// edit, because a returning row is visible and fixable while a discarded edit is neither.
    @Test func aDeleteRacingAnEditBringsTheRowBack() throws {
        try deviceA.execute("INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
            ["n1/RoundTripNote", "Original", "Original body"])
        let base = try #require(try deviceA.drain())
        try copyVersions(from: deviceA, to: deviceB, upTo: base)
        deviceB.head = base
        try deviceB.table.apply(try deviceA.store.valueChanges(madeInVersionIdentifiedBy: base), in: deviceB.database)

        // A deletes the row.
        try deviceA.execute("DELETE FROM notes WHERE llvs_id = ?", ["n1/RoundTripNote"])
        let deleted = try #require(try deviceA.drain())

        // B edits it instead.
        try deviceB.execute("UPDATE notes SET body = ? WHERE llvs_id = ?", ["Edited", "n1/RoundTripNote"])
        let edited = try #require(try deviceB.drain())

        try copyVersions(from: deviceA, to: deviceB, upTo: deleted)
        let merged = try deviceB.store.merge(version: edited, with: deleted, resolvingWith: arbiter())

        let note = try deviceB.note("n1/RoundTripNote", at: merged.id)
        #expect(note != nil, "the design states an edit beats a delete, so the row should return")
        #expect(note?.body == "Edited")
    }

    /// Both devices changing the same column is a real conflict, and the arbiter settles it.
    /// The point here is that it resolves rather than failing or losing the row.
    @Test func twoDevicesEditingTheSameColumnResolveThroughTheArbiter() throws {
        try deviceA.execute("INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
            ["n1/RoundTripNote", "Original", "Original body"])
        let base = try #require(try deviceA.drain())
        try copyVersions(from: deviceA, to: deviceB, upTo: base)
        deviceB.head = base
        try deviceB.table.apply(try deviceA.store.valueChanges(madeInVersionIdentifiedBy: base), in: deviceB.database)

        try deviceA.execute("UPDATE notes SET title = ? WHERE llvs_id = ?", ["A's title", "n1/RoundTripNote"])
        let versionA = try #require(try deviceA.drain())

        try deviceB.execute("UPDATE notes SET title = ? WHERE llvs_id = ?", ["B's title", "n1/RoundTripNote"])
        let versionB = try #require(try deviceB.drain())

        try copyVersions(from: deviceA, to: deviceB, upTo: versionA)
        let merged = try deviceB.store.merge(version: versionB, with: versionA, resolvingWith: arbiter())

        let note = try #require(try deviceB.note("n1/RoundTripNote", at: merged.id))
        #expect(["A's title", "B's title"].contains(note.title))
        // The untouched column is unharmed either way.
        #expect(note.body == "Original body")
    }
}
