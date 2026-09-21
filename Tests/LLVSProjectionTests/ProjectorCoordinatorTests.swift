//
//  ProjectorCoordinatorTests.swift
//  LLVSProjectionTests
//
//  Created by Drew McCormack on 20/09/2026.
//

import Testing
import Foundation
@testable import LLVS
@testable import LLVSSQLite
@testable import LLVSProjection

@Suite class ProjectorCoordinatorTests {

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

    /// Polls for an expected result rather than sleeping a fixed time, which is only long
    /// enough while the machine is idle.
    private func waitForTitles(_ expected: [String], in follower: ProjectionFollower) async throws -> [String] {
        for _ in 0..<200 {
            let current = try await titles(in: follower)
            if current == expected { return current }
            try await Task.sleep(for: .milliseconds(25))
        }
        return try await titles(in: follower)
    }

    private func titles(in follower: ProjectionFollower) async throws -> [String] {
        try await follower.query { database in
            var result: [String] = []
            try database.forEach(matchingQuery: "SELECT title FROM notes ORDER BY title") { row in
                if let title: String = row.value(inColumnAtIndex: 0) { result.append(title) }
            }
            return result
        }
    }

    @Test func projectsTheCurrentVersionAfterASave() async throws {
        let follower = try makeFollower()

        try coordinator.save(inserting: [ProjectionTestSupport.note("a", "Alpha")])
        await follower.projectCurrentVersion()
        #expect(try await titles(in: follower) == ["Alpha"])

        try coordinator.save(inserting: [ProjectionTestSupport.note("b", "Beta")])
        await follower.projectCurrentVersion()
        #expect(try await titles(in: follower) == ["Alpha", "Beta"])
    }

    /// Work saved before the follower exists must still be picked up, or a projection added
    /// to an app that has been running would begin permanently behind.
    @Test func catchesUpWithWorkDoneBeforehand() async throws {
        try coordinator.save(inserting: [ProjectionTestSupport.note("a", "Alpha")])
        try coordinator.save(inserting: [ProjectionTestSupport.note("b", "Beta")])

        let follower = try makeFollower()
        await follower.projectCurrentVersion()

        #expect(try await titles(in: follower) == ["Alpha", "Beta"])
    }

    @Test func reportsWhatEachPassApplied() async throws {
        let follower = try makeFollower()
        try coordinator.save(inserting: [ProjectionTestSupport.note("a", "Alpha")])

        let result = await follower.projectCurrentVersion()

        guard case let .success(projection) = result else {
            Issue.record("expected a successful pass, got \(result)")
            return
        }
        #expect(projection.appliedCount == 1)
        #expect(projection.unreadableIds.isEmpty)
    }

    @Test func reportsAnUnreadableValueThroughTheResult() async throws {
        let follower = try makeFollower()
        try coordinator.save(inserting: [
            ProjectionTestSupport.note("a", "Alpha"),
            ProjectionTestSupport.note("bad", "CORRUPT"),
        ])

        let result = await follower.projectCurrentVersion()

        guard case let .success(projection) = result else {
            Issue.record("expected a successful pass, got \(result)")
            return
        }
        #expect(projection.unreadableIds.map(\.rawValue) == ["bad/Note"])
        #expect(try await titles(in: follower) == ["Alpha"])
    }

    @Test func projectingTwiceWithNoSaveInBetweenAppliesNothing() async throws {
        let follower = try makeFollower()
        try coordinator.save(inserting: [ProjectionTestSupport.note("a", "Alpha")])

        await follower.projectCurrentVersion()
        let second = await follower.projectCurrentVersion()

        guard case let .success(projection) = second else {
            Issue.record("expected a successful pass, got \(second)")
            return
        }
        #expect(projection.appliedCount == 0)
        #expect(try await titles(in: follower) == ["Alpha"])
    }

    /// `followUpdates` must project what is already there before it waits for anything new,
    /// so an app that only ever uses the stream still starts from the right place.
    @Test func followUpdatesProjectsTheCurrentVersionFirst() async throws {
        try coordinator.save(inserting: [ProjectionTestSupport.note("a", "Alpha")])
        let follower = try makeFollower()

        // Run the loop until its first pass lands, then stop: the stream itself never
        // finishes, so the task must be cancelled rather than awaited to completion.
        let task = Task {
            await follower.followUpdates { _ in }
        }
        defer { task.cancel() }

        // Wait for the row rather than for a fixed time. A sleep long enough on an idle
        // machine is not long enough on a busy one, and this failed exactly that way in a
        // full-suite run while passing ten times on its own.
        let titles = try await waitForTitles(["Alpha"], in: follower)
        #expect(titles == ["Alpha"])
    }
}
