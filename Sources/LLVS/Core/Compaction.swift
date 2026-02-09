//
//  Compaction.swift
//  LLVS
//
//  Created by Drew McCormack on 08/02/2026.
//

import Foundation

/// Controls when compaction runs.
public enum CompactionPolicy {
    /// Automatically compact on startup when heuristics suggest it is worthwhile. (Default)
    case auto
    /// Compaction only runs when explicitly requested via compact().
    case manual
    /// Compaction is disabled entirely.
    case none
}

/// Persistent record of compaction state.
/// Stored as JSON at {store.rootDirectoryURL}/compaction.json
public struct CompactionInfo: Codable {

    /// The baseline version created by the most recent compaction.
    public var baselineVersionId: Version.ID?

    /// All version IDs that have been compressed (data deleted).
    public var compressedVersionIds: Set<Version.ID>

    /// True if Phase 3 cleanup hasn't completed yet.
    public var pendingCleanup: Bool

    public init() {
        self.compressedVersionIds = []
        self.pendingCleanup = false
    }
}
