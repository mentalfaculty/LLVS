//
//  ProjectorTests.swift
//  LLVSProjectionTests
//
//  Created by Drew McCormack on 20/09/2026.
//

import Testing
import Foundation
@testable import LLVS
@testable import LLVSSQLite
@testable import LLVSProjection

/// A value whose stored data is simply its title, so these tests need no Codable setup.
/// The title "CORRUPT" stands in for data this build cannot decode.
enum ProjectionTestSupport {
    enum Failure: Swift.Error { case undecodable }

    static func noteType() -> ProjectedType {
        ProjectedType(
            typeIdentifier: "Note",
            tableName: "notes",
            columns: [ProjectedColumn(name: "title", declaration: "TEXT")],
            extract: { value in
                let text = String(decoding: value.data, as: UTF8.self)
                guard text != "CORRUPT" else { throw Failure.undecodable }
                return ["title": .text(text)]
            }
        )
    }

    static func note(_ id: String, _ title: String) -> Value {
        Value(id: .init("\(id)/Note"), data: title.data(using: .utf8)!)
    }
}

@Suite class ProjectorTests {

    let store: Store
    let database: SQLiteDatabase
    let rootURL: URL
    let databaseURL: URL

    init() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store = try Store(rootDirectoryURL: rootURL)
        databaseURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".sqlite")
        database = try SQLiteDatabase(fileURL: databaseURL)
    }

    deinit {
        try? database.close()
        try? FileManager.default.removeItem(at: databaseURL)
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func makeProjector(schemaVersion: Int = 1) throws -> Projector {
        try Projector(database: database, store: store, types: [ProjectionTestSupport.noteType()], schemaVersion: schemaVersion)
    }

    private func titles() throws -> [String] {
        var result: [String] = []
        try database.forEach(matchingQuery: "SELECT title FROM notes ORDER BY title") { row in
            if let title: String = row.value(inColumnAtIndex: 0) { result.append(title) }
        }
        return result
    }

    @Test func projectsAnInsert() throws {
        let projector = try makeProjector()
        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [ProjectionTestSupport.note("a", "Alpha")])

        try projector.update(to: v1.id)

        #expect(try titles() == ["Alpha"])
        #expect(try projector.projectedVersion() == v1.id)
    }

    @Test func projectsAnUpdateAndARemoval() throws {
        let projector = try makeProjector()
        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [
            ProjectionTestSupport.note("a", "Alpha"),
            ProjectionTestSupport.note("b", "Beta"),
        ])
        try projector.update(to: v1.id)

        let v2 = try store.makeVersion(basedOnPredecessor: v1.id,
            updating: [ProjectionTestSupport.note("a", "Alpha2")],
            removing: [.init("b/Note")])
        try projector.update(to: v2.id)

        #expect(try titles() == ["Alpha2"])
        #expect(try projector.projectedVersion() == v2.id)
    }

    @Test func movingBackwardsRestoresTheEarlierContents() throws {
        let projector = try makeProjector()
        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [ProjectionTestSupport.note("a", "Alpha")])
        let v2 = try store.makeVersion(basedOnPredecessor: v1.id, inserting: [ProjectionTestSupport.note("b", "Beta")])

        try projector.update(to: v2.id)
        #expect(try titles() == ["Alpha", "Beta"])

        try projector.update(to: v1.id)
        #expect(try titles() == ["Alpha"])
        #expect(try projector.projectedVersion() == v1.id)
    }

    /// The case a projection exists to survive: after a sync and merge the new version is
    /// sideways from the projected one, not a descendant of it.
    @Test func projectsBetweenTwoSidewaysVersions() throws {
        let projector = try makeProjector()
        let base = try store.makeVersion(basedOnPredecessor: nil, inserting: [ProjectionTestSupport.note("a", "Base")])
        let left = try store.makeVersion(basedOnPredecessor: base.id, updating: [ProjectionTestSupport.note("a", "Left")])
        let right = try store.makeVersion(basedOnPredecessor: base.id, updating: [ProjectionTestSupport.note("a", "Right")])

        try projector.update(to: left.id)
        #expect(try titles() == ["Left"])

        try projector.update(to: right.id)
        #expect(try titles() == ["Right"])
    }

    @Test func projectingTheSameVersionTwiceChangesNothing() throws {
        let projector = try makeProjector()
        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [ProjectionTestSupport.note("a", "Alpha")])

        try projector.update(to: v1.id)
        let second = try projector.update(to: v1.id)

        #expect(second.appliedCount == 0)
        #expect(try titles() == ["Alpha"])
    }

    @Test func anUnreadableValueIsSkippedAndReported() throws {
        let projector = try makeProjector()
        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [
            ProjectionTestSupport.note("a", "Alpha"),
            ProjectionTestSupport.note("bad", "CORRUPT"),
        ])

        let result = try projector.update(to: v1.id)

        #expect(try titles() == ["Alpha"])
        #expect(result.unreadableIds.map(\.rawValue) == ["bad/Note"])
        // The readable value still landed, and the version still advanced: one value this
        // build cannot decode must not hold up everything else.
        #expect(try projector.projectedVersion() == v1.id)
    }

    @Test func aValueOfAnUnknownTypeIsIgnored() throws {
        let projector = try makeProjector()
        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [
            ProjectionTestSupport.note("a", "Alpha"),
            Value(id: .init("t/Tag"), data: "red".data(using: .utf8)!),
        ])

        let result = try projector.update(to: v1.id)

        #expect(try titles() == ["Alpha"])
        // Unknown is not unreadable: no projected type claims it, so there is nothing to report.
        #expect(result.unreadableIds.isEmpty)
    }

    @Test func rebuildReplacesTheWholeTable() throws {
        let projector = try makeProjector()
        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [
            ProjectionTestSupport.note("a", "Alpha"),
            ProjectionTestSupport.note("b", "Beta"),
        ])
        try projector.update(to: v1.id)

        // Damage the projection behind the projector's back.
        try database.execute(statement: "DELETE FROM notes")
        try projector.rebuild(at: v1.id)

        #expect(try titles() == ["Alpha", "Beta"])
        #expect(try projector.projectedVersion() == v1.id)
    }

    @Test func rebuildDropsRowsThatAreNoLongerPresent() throws {
        let projector = try makeProjector()
        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [
            ProjectionTestSupport.note("a", "Alpha"),
            ProjectionTestSupport.note("b", "Beta"),
        ])
        try projector.update(to: v1.id)

        let v2 = try store.makeVersion(basedOnPredecessor: v1.id, removing: [.init("b/Note")])
        try projector.rebuild(at: v2.id)

        #expect(try titles() == ["Alpha"])
    }

    @Test func theFirstUpdateOnAnEmptyDatabaseBuildsEverything() throws {
        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [
            ProjectionTestSupport.note("a", "Alpha"),
            ProjectionTestSupport.note("b", "Beta"),
        ])
        // No prior projection: update has no version to diff from, so it must build from scratch.
        let projector = try makeProjector()
        try projector.update(to: v1.id)

        #expect(try titles() == ["Alpha", "Beta"])
    }

    @Test func aSchemaVersionBumpForcesARebuild() throws {
        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [ProjectionTestSupport.note("a", "Alpha")])
        let first = try makeProjector(schemaVersion: 1)
        try first.update(to: v1.id)

        // Damage the table, then reopen at a new schema version. The contents of a table
        // built for another schema cannot be trusted, so it must be rebuilt rather than diffed.
        try database.execute(statement: "DELETE FROM notes")
        let second = try makeProjector(schemaVersion: 2)
        try second.update(to: v1.id)

        #expect(try titles() == ["Alpha"])
    }

    @Test func columnsTheExtractOmitsAreWrittenAsNull() throws {
        let type = ProjectedType(
            typeIdentifier: "Note",
            tableName: "notes",
            columns: [
                ProjectedColumn(name: "title", declaration: "TEXT"),
                ProjectedColumn(name: "rank", declaration: "INTEGER"),
            ],
            extract: { value in ["title": .text(String(decoding: value.data, as: UTF8.self))] }
        )
        let projector = try Projector(database: database, store: store, types: [type], schemaVersion: 1)
        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [ProjectionTestSupport.note("a", "Alpha")])
        try projector.update(to: v1.id)

        var rank: Int64? = 99
        try database.forEach(matchingQuery: "SELECT rank FROM notes") { row in
            rank = row.value(inColumnAtIndex: 0)
        }
        #expect(rank == nil)
    }

    @Test func storesEveryKindOfColumnValue() throws {
        let type = ProjectedType(
            typeIdentifier: "Note",
            tableName: "notes",
            columns: [
                ProjectedColumn(name: "title", declaration: "TEXT"),
                ProjectedColumn(name: "rank", declaration: "INTEGER"),
                ProjectedColumn(name: "score", declaration: "REAL"),
            ],
            extract: { _ in ["title": .text("t"), "rank": .integer(7), "score": .real(1.5)] }
        )
        let projector = try Projector(database: database, store: store, types: [type], schemaVersion: 1)
        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [ProjectionTestSupport.note("a", "Alpha")])
        try projector.update(to: v1.id)

        var title: String?
        var rank: Int64?
        var score: Double?
        try database.forEach(matchingQuery: "SELECT title, rank, score FROM notes") { row in
            title = row.value(inColumnAtIndex: 0)
            rank = row.value(inColumnAtIndex: 1)
            score = row.value(inColumnAtIndex: 2)
        }
        #expect(title == "t")
        #expect(rank == 7)
        #expect(score == 1.5)
    }
}
