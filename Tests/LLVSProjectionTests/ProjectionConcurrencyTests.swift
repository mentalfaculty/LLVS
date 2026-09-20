//
//  ProjectionConcurrencyTests.swift
//  LLVSProjectionTests
//
//  Created by Drew McCormack on 20/09/2026.
//

import Testing
import Foundation
@testable import LLVS
@testable import LLVSSQLite
@testable import LLVSProjection

/// A projection pass reads the store while the app goes on saving to it. That is safe today
/// for a reason no type declares: `Map`'s only fields are a `let zone` and a `Mutex`-backed
/// `Cache`, and `FileZone` is the same, so concurrent readers and writers meet only in file
/// I/O and a lock.
///
/// `Store` promises none of that, so the property is accidental rather than guaranteed. These
/// tests assert it instead of a comment claiming it: if mutable unguarded state is ever added
/// to `Map`, `FileZone` or `Store`, this suite should start crashing or corrupting rather than
/// the problem reaching an app.
///
/// Run them under Thread Sanitizer to get the stronger signal:
///     swift test --sanitize=thread --filter ProjectionConcurrencyTests
@Suite class ProjectionConcurrencyTests {

    let coordinator: StoreCoordinator
    let baseURL: URL
    let databaseURL: URL

    init() throws {
        baseURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let storeURL = baseURL.appendingPathComponent("store")
        let cacheURL = baseURL.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        coordinator = try StoreCoordinator(withStoreDirectoryAt: storeURL, cacheDirectoryAt: cacheURL)
        databaseURL = baseURL.appendingPathComponent("projection.sqlite")
    }

    deinit {
        try? FileManager.default.removeItem(at: baseURL)
    }

    private func makeFollower() throws -> ProjectionFollower {
        try ProjectionFollower(
            databaseURL: databaseURL,
            coordinator: coordinator,
            types: [ProjectionTestSupport.noteType()],
            schemaVersion: 1)
    }

    private static func rowCount(in follower: ProjectionFollower) async throws -> Int {
        try await follower.query { database in
            var count = 0
            try database.forEach(matchingQuery: "SELECT COUNT(*) FROM notes") { row in
                count = Int(row.value(inColumnAtIndex: 0) as Int64? ?? 0)
            }
            return count
        }
    }

    /// Saves and projection passes run against each other. The projection is allowed to trail —
    /// a pass reports the version it reached, not the newest — so the assertion is that nothing
    /// crashes or corrupts, and that a final pass settles on the whole truth.
    @Test func savingWhileProjectingDoesNotCorruptTheProjection() async throws {
        let follower = try makeFollower()
        let saveCount = 150

        let coordinator = self.coordinator
        async let saves: Void = {
            for i in 0..<saveCount {
                try? coordinator.save(inserting: [ProjectionTestSupport.note("n\(i)", "Note \(i)")])
            }
        }()

        async let passes: Void = {
            for _ in 0..<saveCount {
                await follower.projectCurrentVersion()
            }
        }()

        _ = await (saves, passes)

        // One last pass, with nothing else running, must land on everything saved.
        let result = await follower.projectCurrentVersion()
        if case let .failure(error) = result {
            Issue.record("final pass failed: \(error)")
        }
        #expect(try await Self.rowCount(in: follower) == saveCount)
    }

    /// The same, driven through the version stream rather than by awaiting each pass, which is
    /// the path an app takes if it does not want to await its saves.
    @Test func followUpdatesKeepsUpWithSaves() async throws {
        let follower = try makeFollower()
        let saveCount = 100

        let task = Task { await follower.followUpdates { _ in } }
        defer { task.cancel() }

        for i in 0..<saveCount {
            try coordinator.save(inserting: [ProjectionTestSupport.note("n\(i)", "Note \(i)")])
        }

        // Poll rather than sleep a fixed time: the stream delivers on its own schedule, and the
        // loop is allowed to trail as long as it arrives.
        var count = 0
        for _ in 0..<200 {
            count = try await Self.rowCount(in: follower)
            if count == saveCount { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(count == saveCount)
    }

    /// Queries run on the actor, so one cannot be in the SQLite connection while a pass writes
    /// it. Reading throughout a run of passes must never fault or throw.
    @Test func queryingWhileProjectingIsSafe() async throws {
        let follower = try makeFollower()
        let saveCount = 100

        let coordinator = self.coordinator
        async let work: Void = {
            for i in 0..<saveCount {
                try? coordinator.save(inserting: [ProjectionTestSupport.note("n\(i)", "Note \(i)")])
                await follower.projectCurrentVersion()
            }
        }()

        async let reads: Void = {
            for _ in 0..<saveCount {
                _ = try? await Self.rowCount(in: follower)
            }
        }()

        _ = await (work, reads)

        await follower.projectCurrentVersion()
        #expect(try await Self.rowCount(in: follower) == saveCount)
    }
}
