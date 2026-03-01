//
//  SnapshotCapable+ZIP.swift
//  LLVS
//
//  Created by Drew McCormack on 01/03/2026.
//

import Foundation
import ZIPFoundation

extension SnapshotCapable {

    public var snapshotFormat: String { "zip-v1" }

    public func writeSnapshotChunks(storeRootURL: URL, to directory: URL, maxChunkSize: Int) throws -> SnapshotManifest {
        let fm = FileManager()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)

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
        while bytesRemaining > 0 {
            let bytesToRead = min(Int(bytesRemaining), maxChunkSize)
            let chunkData = readHandle.readData(ofLength: bytesToRead)
            if chunkData.isEmpty { break }

            let chunkFile = directory.appendingPathComponent(String(format: "chunk-%03d", chunkIndex))
            try chunkData.write(to: chunkFile)
            chunkIndex += 1
            bytesRemaining -= Int64(chunkData.count)
        }

        // Scan versions/ for manifest metadata
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

        return SnapshotManifest(
            format: snapshotFormat,
            latestVersionId: latestVersionId,
            versionCount: versionCount,
            chunkCount: chunkIndex,
            totalSize: totalSize
        )
    }

    public func restoreFromSnapshotChunks(storeRootURL: URL, from directory: URL, manifest: SnapshotManifest) throws {
        let fm = FileManager()

        // Concatenate chunks into a zip file
        let zipURL = directory.appendingPathComponent("snapshot.zip")
        fm.createFile(atPath: zipURL.path, contents: nil)
        let writeHandle = try FileHandle(forWritingTo: zipURL)

        for i in 0..<manifest.chunkCount {
            let chunkFile = directory.appendingPathComponent(String(format: "chunk-%03d", i))
            let chunkData = try Data(contentsOf: chunkFile)
            writeHandle.write(chunkData)
        }
        try writeHandle.close()

        // Unzip to store root
        try fm.unzipItem(at: zipURL, to: storeRootURL)
        try? fm.removeItem(at: zipURL)
    }
}
