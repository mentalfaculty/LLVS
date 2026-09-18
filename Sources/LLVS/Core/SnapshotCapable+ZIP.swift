//
//  SnapshotCapable+ZIP.swift
//  LLVS
//
//  Created by Drew McCormack on 01/03/2026.
//

import Foundation
import ZIPFoundation
import CryptoKit

extension SnapshotCapable {

    public var snapshotFormat: String { "zip-v1" }

    public func writeSnapshotChunks(storeRootURL: URL, to directory: URL, maxChunkSize: Int) throws -> SnapshotManifest {
        let fm = FileManager()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        removeStaleSnapshotStagingDirectories(inStoreAt: storeRootURL) // Else a leftover would be zipped too

        // Scan versions/ for manifest metadata. This is done before zipping, because the store can be in use.
        // The archive then holds at least the versions that the manifest counts.
        let versionsDir = storeRootURL.appendingPathComponent("versions")
        var versionCount = 0
        var latestVersionId = Version.ID("")
        var maxTimestamp: TimeInterval = 0
        if let versionsEnum = fm.enumerator(at: versionsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in versionsEnum {
                guard fileURL.pathExtension == "json" else { continue }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                versionCount += 1
                if let data = try? Data(contentsOf: fileURL),
                   let version = try? JSONDecoder().decode(Version.self, from: data),
                   version.timestamp > maxTimestamp {
                    maxTimestamp = version.timestamp
                    latestVersionId = version.id
                }
            }
        }

        // Create zip of the entire store directory
        let zipURL = directory.appendingPathComponent("snapshot.zip")
        try fm.zipItem(at: storeRootURL, to: zipURL, shouldKeepParent: false, compressionMethod: .deflate)
        defer { try? fm.removeItem(at: zipURL) }

        // Get total compressed size
        let zipAttributes = try fm.attributesOfItem(atPath: zipURL.path)
        let totalSize = (zipAttributes[.size] as? Int64) ?? 0

        // Split zip into chunks using FileHandle for streaming
        let readHandle = try FileHandle(forReadingFrom: zipURL)
        defer { try? readHandle.close() }

        var chunkIndex = 0
        var bytesRemaining = totalSize
        var hasher = SHA256()
        while bytesRemaining > 0 {
            let bytesToRead = min(Int(bytesRemaining), maxChunkSize)
            guard let chunkData = try readHandle.read(upToCount: bytesToRead), !chunkData.isEmpty else { break }

            let chunkFile = directory.appendingPathComponent(String(format: "chunk-%03d", chunkIndex))
            try chunkData.write(to: chunkFile, options: .atomic)
            hasher.update(data: chunkData)
            chunkIndex += 1
            bytesRemaining -= Int64(chunkData.count)
        }

        return SnapshotManifest(
            format: snapshotFormat,
            latestVersionId: latestVersionId,
            versionCount: versionCount,
            chunkCount: chunkIndex,
            totalSize: totalSize,
            sha256: hasher.finalize().hexString
        )
    }

    public func restoreFromSnapshotChunks(storeRootURL: URL, from directory: URL, manifest: SnapshotManifest) throws {
        let fm = FileManager()

        // Concatenate chunks into a zip file
        let zipURL = directory.appendingPathComponent("snapshot.zip")
        fm.createFile(atPath: zipURL.path, contents: nil)
        defer { try? fm.removeItem(at: zipURL) }
        let writeHandle = try FileHandle(forWritingTo: zipURL)
        var assembledSize: Int64 = 0
        var hasher = SHA256()
        do {
            defer { try? writeHandle.close() }
            for i in 0..<manifest.chunkCount {
                let chunkFile = directory.appendingPathComponent(String(format: "chunk-%03d", i))
                let chunkData = try Data(contentsOf: chunkFile)
                try writeHandle.write(contentsOf: chunkData)
                hasher.update(data: chunkData)
                assembledSize += Int64(chunkData.count)
            }
        }

        // The chunks can belong to a different snapshot, if one was being replaced during the download.
        // Unzipping is no check: ZIPFoundation stops without an error at an entry it cannot read.
        guard assembledSize == manifest.totalSize else {
            throw SnapshotRestoreError.chunksDoNotMatchManifest
        }
        if let expectedHash = manifest.sha256, expectedHash != hasher.finalize().hexString {
            throw SnapshotRestoreError.chunksDoNotMatchManifest
        }

        // Unzip to a staging directory first, so that a failure leaves the store as it was.
        // It is a hidden directory in the store, so that the moves below are renames on one volume.
        // Two processes restoring at once could remove each other's staging. One then fails at a move,
        // and the store stays valid, because versions move last.
        removeStaleSnapshotStagingDirectories(inStoreAt: storeRootURL)
        let stagingURL = storeRootURL.appendingPathComponent(snapshotStagingPrefix + UUID().uuidString)
        try fm.createDirectory(at: stagingURL, withIntermediateDirectories: true, attributes: nil)
        defer { try? fm.removeItem(at: stagingURL) }
        try fm.unzipItem(at: zipURL, to: stagingURL)

        // Take only the directories of a store. The archive can hold other files (eg the uploader's Coordinator.json).
        let stagingPath = stagingURL.resolvingSymlinksInPath().path
        var versionFiles: [(source: URL, relativePath: String)] = []
        var otherFiles: [(source: URL, relativePath: String)] = []
        if let enumerator = fm.enumerator(at: stagingURL, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let fileURL as URL in enumerator {
                guard try fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                let relativePath = String(fileURL.resolvingSymlinksInPath().path.dropFirst(stagingPath.count + 1))
                switch relativePath.split(separator: "/").first {
                case "versions": versionFiles.append((fileURL, relativePath))
                case "values", "maps": otherFiles.append((fileURL, relativePath))
                default: continue
                }
            }
        }

        // Snapshots made before 0.10 have no hash. The version count then guards against a partial unzip.
        let stagedVersionCount = versionFiles.filter({ $0.source.pathExtension == "json" }).count
        guard stagedVersionCount >= manifest.versionCount else {
            throw SnapshotRestoreError.archiveIsIncomplete(expectedVersionCount: manifest.versionCount, actualVersionCount: stagedVersionCount)
        }

        // Decide what to move before moving anything, so that an error leaves the store as it was.
        // Files in a file-based store never change, so an existing file with the same content is skipped.
        // Anything else (eg a SQLite database) cannot be merged, and must not be kept silently.
        var filesToMove: [(source: URL, destination: URL)] = []
        for (source, relativePath) in otherFiles + versionFiles {
            let destinationURL = storeRootURL.appendingPathComponent(relativePath)
            if fm.fileExists(atPath: destinationURL.path) {
                guard fm.contentsEqual(atPath: source.path, andPath: destinationURL.path) else {
                    throw SnapshotRestoreError.destinationExists(relativePath: relativePath)
                }
            } else {
                filesToMove.append((source, destinationURL))
            }
        }

        // A version file is what makes a version exist, so versions go last. If the moves stop part way,
        // the store has at most some values and map nodes that nothing refers to.
        for (source, destinationURL) in filesToMove {
            try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            try fm.moveItem(at: source, to: destinationURL)
        }
    }
}

/// A restore that was interrupted (eg a crash) leaves its staging directory in the store.
private let snapshotStagingPrefix = ".llvs-restore-"

private func removeStaleSnapshotStagingDirectories(inStoreAt storeRootURL: URL) {
    let fm = FileManager()
    for url in (try? fm.contentsOfDirectory(at: storeRootURL, includingPropertiesForKeys: nil)) ?? [] where url.lastPathComponent.hasPrefix(snapshotStagingPrefix) {
        try? fm.removeItem(at: url)
    }
}

public enum SnapshotRestoreError: Swift.Error {
    case chunksDoNotMatchManifest
    case archiveIsIncomplete(expectedVersionCount: Int, actualVersionCount: Int)
    case destinationExists(relativePath: String)
}

private extension SHA256.Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
