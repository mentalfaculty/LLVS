//
//  Projector+Coordinator.swift
//  LLVS
//
//  Created by Drew McCormack on 20/09/2026.
//

import Foundation
import LLVS
import LLVSSQLite

/// Keeps a projection in step with a `StoreCoordinator`.
///
/// An actor, because neither `Projector` nor the `SQLiteDatabase` beneath it is thread-safe,
/// and a projection pass writes that database while the app reads it to answer queries. Two
/// threads in one SQLite connection crash the process, so every pass and every query runs
/// here instead.
///
/// A pass also reads the `Store`, which offers no serialisation contract of its own
/// (`AUDIT.md` item 9). That it is safe to do so while the app saves is a property of today's
/// implementation rather than a promise; `StoreConcurrencyTests` in `LLVSTests` is what holds
/// it in place.
///
/// ```swift
/// let follower = try ProjectionFollower(
///     databaseURL: url, coordinator: coordinator, types: types, schemaVersion: 1)
///
/// try coordinator.save(inserting: [value])
/// await follower.projectCurrentVersion()
///
/// let titles = try await follower.query { db in
///     var titles: [String] = []
///     try db.forEach(matchingQuery: "SELECT title FROM notes") { row in
///         if let title: String = row.value(inColumnAtIndex: 0) { titles.append(title) }
///     }
///     return titles
/// }
/// ```
///
/// `followUpdates()` drives the same thing from `currentVersionUpdates` for an app that does
/// not want to await each save. That stream has a single consumer, so only one follower can
/// drain it, and an app that uses it should not also be calling `projectCurrentVersion()`
/// from elsewhere — the actor keeps the two from overlapping, but the ordering is then the
/// stream's rather than the app's.
public actor ProjectionFollower {

    private let database: SQLiteDatabase
    private let projector: Projector
    private let coordinator: StoreCoordinator

    /// The database and projector are built here rather than passed in, so that neither is
    /// reachable from outside this actor. Neither is thread-safe, and handing one over after
    /// the fact would leave the caller holding a reference it could still use while a pass
    /// was running.
    public init(
        databaseURL: URL,
        coordinator: StoreCoordinator,
        types: [ProjectedType],
        schemaVersion: Int
    ) throws {
        self.database = try SQLiteDatabase(fileURL: databaseURL)
        self.projector = try Projector(
            database: database,
            store: coordinator.store,
            types: types,
            schemaVersion: schemaVersion)
        self.coordinator = coordinator
    }

    /// Reads the projected database. This is how an app queries it: the connection stays on
    /// the actor, so a query cannot run while a projection pass is writing.
    ///
    /// The `SQLiteDatabase` cannot escape the block: it is not `Sendable`, the block is not
    /// `@Sendable`, and the return type must be. Extract what you need and return that.
    public func query<T: Sendable>(_ block: (SQLiteDatabase) throws -> T) throws -> T {
        try block(database)
    }

    /// Brings the projection up to the coordinator's current version.
    ///
    /// Call this after a save. The result carries what was applied, and any values that could
    /// not be read; a failure comes back as `.failure` rather than throwing, because a pass
    /// that fails is not fatal — the version marker stays put and the next pass repeats it.
    @discardableResult
    public func projectCurrentVersion() -> Result<ProjectionResult, any Swift.Error> {
        Result { try projector.update(to: coordinator.currentVersion) }
    }

    /// Projects the current version, then every version the coordinator moves to, until the
    /// calling task is cancelled.
    ///
    /// The first pass catches up with whatever has already happened, so a projection started
    /// after the app has been running does not begin permanently behind.
    ///
    /// A pass that fails is reported and the loop continues: the marker stays where it was,
    /// so the next version covers the same ground again. That is the intended failure mode —
    /// behind, and repairing itself — rather than a stalled loop.
    public func followUpdates(onResult: @Sendable (Result<ProjectionResult, any Swift.Error>) -> Void) async {
        onResult(projectCurrentVersion())
        for await version in coordinator.currentVersionUpdates {
            if Task.isCancelled { return }
            onResult(Result { try projector.update(to: version) })
        }
    }
}
