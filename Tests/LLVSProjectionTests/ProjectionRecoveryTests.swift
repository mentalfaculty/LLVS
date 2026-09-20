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
///
/// `aFailureMidPassLeavesTheProjectionUnchanged` and
/// `aFailureMidPassDoesNotDisturbWhatWasAlreadyProjected` are the atomicity guards. Removing
/// `BEGIN`/`COMMIT` from `SQLiteDatabase.inTransaction` fails both, every run. The other
/// tests here cover recovery and reporting; without a transaction the work still completes,
/// so they are not guards and are not expected to catch its removal.
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

    /// Makes a pass fail on its `failOnInsertNumber`-th insert, so rows have certainly landed
    /// before it fails.
    ///
    /// Counting inserts rather than rejecting a particular title is deliberate. `Map.differences`
    /// builds its result from `Set`s of keys and IDs, and Swift seeds its hasher per process, so
    /// the order of the changes in a pass varies from run to run. A constraint on one row's
    /// content is therefore hit first on some runs and last on others; on the runs where it goes
    /// first, nothing has been written and there is nothing to roll back, and the test passes
    /// whether or not the transaction exists. Failing on a count holds whatever the order.
    private func failPass(onInsertNumber failOnInsertNumber: Int) throws {
        try database.execute(statement: "DROP TABLE IF EXISTS notes")
        try database.execute(statement: ProjectionTestSupport.noteType().createTableStatement())
        try database.execute(statement: """
            CREATE TRIGGER fail_late BEFORE INSERT ON notes
            WHEN (SELECT COUNT(*) FROM notes) >= \(failOnInsertNumber - 1)
            BEGIN
                SELECT RAISE(ABORT, 'projection test: induced failure');
            END
            """)
    }

    /// Removes the induced failure, standing in for its cause being lifted — a fixed build,
    /// freed disk space.
    private func stopFailing() throws {
        try database.execute(statement: "DROP TRIGGER IF EXISTS fail_late")
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
        // Fail on the third insert, so two rows have certainly landed first.
        try failPass(onInsertNumber: 3)
        let projector = try makeProjector()
        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [
            ProjectionTestSupport.note("a", "Alpha"),
            ProjectionTestSupport.note("b", "Beta"),
            ProjectionTestSupport.note("c", "Charlie"),
        ])

        #expect(throws: (any Swift.Error).self) {
            try self.projectorUpdate(projector, to: v1.id)
        }

        // Without a transaction, the two rows written before the failure would be here.
        #expect(try titles() == [])
        #expect(try projector.projectedVersion() == nil)
    }

    /// The same, one pass later: rows already projected must not be disturbed by a later
    /// pass that fails part-way through its own writes.
    @Test func aFailureMidPassDoesNotDisturbWhatWasAlreadyProjected() throws {
        let projector = try makeProjector()
        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [ProjectionTestSupport.note("a", "Alpha")])
        try projector.update(to: v1.id)
        #expect(try titles() == ["Alpha"])

        // One row is already projected, so failing on the third insert overall means the
        // second pass writes two of its own rows before it fails.
        try database.execute(statement: """
            CREATE TRIGGER fail_late BEFORE INSERT ON notes
            WHEN (SELECT COUNT(*) FROM notes) >= 2
            BEGIN
                SELECT RAISE(ABORT, 'projection test: induced failure');
            END
            """)

        let v2 = try store.makeVersion(basedOnPredecessor: v1.id, inserting: [
            ProjectionTestSupport.note("b", "Beta"),
            ProjectionTestSupport.note("c", "Charlie"),
        ])

        #expect(throws: (any Swift.Error).self) {
            try self.projectorUpdate(projector, to: v2.id)
        }

        // Whichever of the two went first was written, and must have gone back.
        #expect(try titles() == ["Alpha"])
        #expect(try projector.projectedVersion() == v1.id)
    }

    /// Repeating a failed pass after the cause is gone must complete it, because the marker
    /// never moved and the same difference is asked for again.
    @Test func rerunningAfterAFailureCompletesTheWork() throws {
        try failPass(onInsertNumber: 2)
        let projector = try makeProjector()
        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [
            ProjectionTestSupport.note("a", "Alpha"),
            ProjectionTestSupport.note("b", "Beta"),
        ])

        #expect(throws: (any Swift.Error).self) {
            try self.projectorUpdate(projector, to: v1.id)
        }
        #expect(try projector.projectedVersion() == nil)

        // Lift the cause, as a fixed build or a freed disk would, and run the same pass again.
        // It asks for the same difference, because the marker never moved.
        try stopFailing()
        try projector.update(to: v1.id)

        #expect(try titles() == ["Alpha", "Beta"])
        #expect(try projector.projectedVersion() == v1.id)
    }

    /// A rolled-back pass must leave the connection usable, not stuck inside an open transaction.
    @Test func theDatabaseIsUsableAfterAFailedPass() throws {
        try failPass(onInsertNumber: 2)
        let projector = try makeProjector()
        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [
            ProjectionTestSupport.note("a", "Alpha"),
            ProjectionTestSupport.note("b", "Beta"),
        ])
        #expect(throws: (any Swift.Error).self) {
            try self.projectorUpdate(projector, to: v1.id)
        }

        // A further write would fail with "cannot start a transaction within a transaction"
        // if the rollback had not run.
        try stopFailing()
        try projector.rebuild(at: v1.id)
        #expect(try titles() == ["Alpha", "Beta"])
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
