//
//  Snapshot.swift
//  LLVS
//
//  Created by Drew McCormack on 09/02/2026.
//

import Foundation

/// Metadata describing a snapshot stored in the cloud.
public struct SnapshotManifest: Codable {
    public var snapshotId: String
    public var format: String
    public var createdAt: Date
    public var latestVersionId: Version.ID
    public var versionCount: Int
    public var chunkCount: Int
    public var totalSize: Int64

    /// Hex SHA-256 of the whole archive (all chunks, in order). Nil for snapshots made before 0.10.
    public var sha256: String?

    public init(snapshotId: String = UUID().uuidString, format: String, createdAt: Date = Date(), latestVersionId: Version.ID, versionCount: Int, chunkCount: Int, totalSize: Int64, sha256: String? = nil) {
        self.snapshotId = snapshotId
        self.format = format
        self.createdAt = createdAt
        self.latestVersionId = latestVersionId
        self.versionCount = versionCount
        self.chunkCount = chunkCount
        self.totalSize = totalSize
        self.sha256 = sha256
    }
}

/// Policy controlling automatic snapshot creation after sync.
public struct SnapshotPolicy {
    public var enabled: Bool
    public var minimumInterval: TimeInterval
    public var minimumNewVersions: Int

    public init(enabled: Bool, minimumInterval: TimeInterval, minimumNewVersions: Int) {
        self.enabled = enabled
        self.minimumInterval = minimumInterval
        self.minimumNewVersions = minimumNewVersions
    }

    public static let auto = SnapshotPolicy(
        enabled: true, minimumInterval: 7*24*3600, minimumNewVersions: 20
    )
    public static let disabled = SnapshotPolicy(
        enabled: false, minimumInterval: 0, minimumNewVersions: 0
    )
}
