//
//  ProjectionRecoveryTests.swift
//  LLVSProjectionTests
//
//  Created by Drew McCormack on 20/09/2026.
//

import Testing
import Foundation
@testable import LLVS
@testable import LLVSSQLite
@testable import LLVSProjection

/// The claim these tests exist to check: a pass that fails part-way leaves the projection
/// exactly as it was, so the database is never half-updated, and running again finishes
/// the work. Everything else in the design rests on it.
@Suite class ProjectionRecoveryTests {

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

    private func makeProjector() throws -> Projector {
        try Projector(database: database, store: store, types: [ProjectionTestSupport.noteType()], schemaVersion: 1)
    }

    /// Rejects one particular title at the database level, so a pass fails *after* it has
    /// already written other rows. A failure on the pass's first write would prove nothing:
    /// there would be nothing written to roll back.
    private func rejectTitle(_ title: String) throws {
        try database.execute(statement: "DROP TABLE IF EXISTS notes")
        try database.execute(statement: """
            CREATE TABLE notes (llvs_id TEXT PRIMARY KEY, title TEXT CHECK (title <> '\(title)'))
            """)
    }

    /// Replaces the constrained table with an ordinary one, standing in for the cause of a
    /// failure being lifted — a fixed build, freed disk space.
    private func acceptEveryTitle() throws {
        try database.execute(statement: "DROP TABLE IF EXISTS notes")
        try database.execute(statement: ProjectionTestSupport.noteType().createTableStatement())
    }

    private func titles() throws -> [String] {
        var result: [String] = []
        try database.forEach(matchingQuery: "SELECT title FROM notes ORDER BY title") { row in
            if let title: String = row.value(inColumnAtIndex: 0) { result.append(title) }
        }
        return result
    }

    /// A write that fails mid-pass must take the version marker down with it. If the marker
    /// advanced, the next pass would diff from a version whose rows never landed, and the
    /// missing rows would never be noticed.
    @Test func aFailureMidPassLeavesTheProjectionUnchanged() throws {
        // Reject "Poison" before anything is projected, so the very first pass writes some
        // rows and then fails on one of them.
        try rejectTitle("Poison")
        let projector = try makeProjector()
        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [
            ProjectionTestSupport.note("a", "Alpha"),
            ProjectionTestSupport.note("b", "Beta"),
            ProjectionTestSupport.note("p", "Poison"),
        ])

        #expect(throws: (any Swift.Error).self) {
            try self.projectorUpdate(projector, to: v1.id)
        }

        // Without a transaction, "Alpha" and "Beta" would be sitting in the table here.
        #expect(try titles() == [])
        #expect(try projector.projectedVersion() == nil)
    }

    /// The same, one pass later: rows already projected must not be disturbed by a later
    /// pass that fails part-way through its own writes.
    @Test func aFailureMidPassDoesNotDisturbWhatWasAlreadyProjected() throws {
        let projector = try makeProjector()
        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [ProjectionTestSupport.note("a", "Alpha")])
        try projector.update(to: v1.id)

        // Rebuild the table with the constraint, keeping the row that is already there.
        try database.execute(statement: "DROP TABLE notes")
        try database.execute(statement: """
            CREATE TABLE notes (llvs_id TEXT PRIMARY KEY, title TEXT CHECK (title <> 'Poison'))
            """)
        try database.execute(statement: "INSERT INTO notes (llvs_id, title) VALUES (?, ?)",
            withBindingsList: [["a/Note", "Alpha"]])

        let v2 = try store.makeVersion(basedOnPredecessor: v1.id, inserting: [
            ProjectionTestSupport.note("b", "Beta"),
            ProjectionTestSupport.note("p", "Poison"),
        ])

        #expect(throws: (any Swift.Error).self) {
            try self.projectorUpdate(projector, to: v2.id)
        }

        // "Beta" was written before "Poison" failed, and must have gone back.
        #expect(try titles() == ["Alpha"])
        #expect(try projector.projectedVersion() == v1.id)
    }

    /// Repeating a failed pass after the cause is gone must complete it, because the marker
    /// never moved and the same difference is asked for again.
    @Test func rerunningAfterAFailureCompletesTheWork() throws {
        try rejectTitle("Poison")
        let projector = try makeProjector()
        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [
            ProjectionTestSupport.note("a", "Alpha"),
            ProjectionTestSupport.note("p", "Poison"),
        ])

        #expect(throws: (any Swift.Error).self) {
            try self.projectorUpdate(projector, to: v1.id)
        }
        #expect(try projector.projectedVersion() == nil)

        // Lift the cause, as a fixed build or a freed disk would, and run the same pass again.
        // It asks for the same difference, because the marker never moved.
        try acceptEveryTitle()
        try projector.update(to: v1.id)

        #expect(try titles() == ["Alpha", "Poison"])
        #expect(try projector.projectedVersion() == v1.id)
    }

    /// A rolled-back pass must leave the connection usable, not stuck inside an open transaction.
    @Test func theDatabaseIsUsableAfterAFailedPass() throws {
        try rejectTitle("Poison")
        let projector = try makeProjector()
        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [
            ProjectionTestSupport.note("a", "Alpha"),
            ProjectionTestSupport.note("p", "Poison"),
        ])
        #expect(throws: (any Swift.Error).self) {
            try self.projectorUpdate(projector, to: v1.id)
        }

        // A further write would fail with "cannot start a transaction within a transaction"
        // if the rollback had not run.
        try acceptEveryTitle()
        try projector.rebuild(at: v1.id)
        #expect(try titles() == ["Alpha", "Poison"])
    }

    /// An unreadable value is not a failure: the pass completes, the marker advances, and only
    /// that one value is left out. This is the difference between skip-and-report and failing.
    @Test func anUnreadableValueDoesNotRollThePassBack() throws {
        let projector = try makeProjector()
        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [
            ProjectionTestSupport.note("a", "Alpha"),
            ProjectionTestSupport.note("bad", "CORRUPT"),
            ProjectionTestSupport.note("c", "Charlie"),
        ])

        let result = try projector.update(to: v1.id)

        #expect(try titles() == ["Alpha", "Charlie"])
        #expect(result.unreadableIds.map(\.rawValue) == ["bad/Note"])
        #expect(try projector.projectedVersion() == v1.id)
    }

    /// Once the value can be decoded, a rebuild picks it up. Nothing was lost by skipping it.
    @Test func aValueThatBecomesReadableIsPickedUpByARebuild() throws {
        let projector = try makeProjector()
        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [
            ProjectionTestSupport.note("a", "Alpha"),
            ProjectionTestSupport.note("bad", "CORRUPT"),
        ])
        let first = try projector.update(to: v1.id)
        #expect(first.unreadableIds.count == 1)

        // A later build understands the value, which here means the data stops saying CORRUPT.
        let v2 = try store.makeVersion(basedOnPredecessor: v1.id,
            updating: [ProjectionTestSupport.note("bad", "Readable")])
        let second = try projector.update(to: v2.id)

        #expect(second.unreadableIds.isEmpty)
        #expect(try titles() == ["Alpha", "Readable"])
    }

    /// `update` is `@discardableResult`, so this wrapper exists only to give the throwing
    /// expectations above something to call that is unambiguous to the compiler.
    private func projectorUpdate(_ projector: Projector, to version: Version.ID) throws {
        _ = try projector.update(to: version)
    }
}
