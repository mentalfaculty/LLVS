//
//  SQLiteZone.swift
//  LLVS
//
//  Created by Drew McCormack on 14/05/2019.
//

import Foundation
import LLVS
import SQLite3

public class SQLiteStorage: Storage, SnapshotCapable {

    private let fileExtension = "sqlite"

    public init() {}

    public func makeMapZone(for type: MapType, in store: Store) throws -> Zone {
        switch type {
        case .valuesByVersion:
            return try SQLiteZone(rootDirectory: store.valuesMapDirectoryURL, fileExtension: fileExtension)
        case .userDefined:
            fatalError("User defined maps not yet supported")
        }
    }

    public func makeValuesZone(in store: Store) throws -> Zone {
        return try SQLiteZone(rootDirectory: store.valuesDirectoryURL, fileExtension: fileExtension)
    }

    // MARK: SnapshotCapable

    public var snapshotFormat: String { "sqliteStorage-v1" }

    public func writeSnapshotChunks(storeRootURL: URL, to directory: URL, maxChunkSize: Int) throws -> SnapshotManifest {
        let fm = FileManager()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)

        let rootPath = storeRootURL.resolvingSymlinksInPath().path
        var chunkIndex = 0
        var currentChunkData = Data()
        var totalSize: Int64 = 0

        func flushChunk() throws {
            if !currentChunkData.isEmpty {
                let chunkFile = directory.appendingPathComponent(String(format: "chunk-%03d", chunkIndex))
                try currentChunkData.write(to: chunkFile)
                chunkIndex += 1
                currentChunkData = Data()
            }
        }

        // Walk all files under storeRootURL
        guard let enumerator = fm.enumerator(at: storeRootURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return SnapshotManifest(format: snapshotFormat, latestVersionId: .init(""), versionCount: 0, chunkCount: 0, totalSize: 0)
        }

        for case let fileURL as URL in enumerator {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }

            let resolvedFilePath = fileURL.resolvingSymlinksInPath().path
            let relativePath = String(resolvedFilePath.dropFirst(rootPath.count + 1))
            let pathData = relativePath.data(using: .utf8)!
            let fileData = try Data(contentsOf: fileURL)

            // Entry format: [UInt32 pathLen][UTF8 path][UInt32 dataLen][data]
            var entry = Data()
            var pathLen = UInt32(pathData.count)
            entry.append(Data(bytes: &pathLen, count: 4))
            entry.append(pathData)
            var dataLen = UInt32(fileData.count)
            entry.append(Data(bytes: &dataLen, count: 4))
            entry.append(fileData)

            totalSize += Int64(entry.count)

            if !currentChunkData.isEmpty && currentChunkData.count + entry.count > maxChunkSize {
                try flushChunk()
            }
            currentChunkData.append(entry)
        }
        try flushChunk()

        // Determine version count and latest version by scanning versions/ subdirectory
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
        let rootPath = storeRootURL.resolvingSymlinksInPath().path

        for i in 0..<manifest.chunkCount {
            let chunkFile = directory.appendingPathComponent(String(format: "chunk-%03d", i))
            let chunkData = try Data(contentsOf: chunkFile)

            var offset = 0
            while offset < chunkData.count {
                guard offset + 4 <= chunkData.count else { break }
                let pathLen = Self.readUInt32(from: chunkData, at: offset)
                offset += 4

                guard offset + Int(pathLen) <= chunkData.count else { break }
                let pathData = chunkData[offset..<offset+Int(pathLen)]
                let relativePath = String(data: pathData, encoding: .utf8)!
                offset += Int(pathLen)

                guard offset + 4 <= chunkData.count else { break }
                let dataLen = Self.readUInt32(from: chunkData, at: offset)
                offset += 4

                guard offset + Int(dataLen) <= chunkData.count else { break }
                let fileData = chunkData[offset..<offset+Int(dataLen)]
                offset += Int(dataLen)

                let filePath = rootPath + "/" + relativePath
                let fileURL = URL(fileURLWithPath: filePath)
                try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
                try fileData.write(to: fileURL)
            }
        }
    }

    private static func readUInt32(from data: Data, at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &value) { dest in
            data.copyBytes(to: dest, from: offset..<offset+4)
        }
        return value
    }

}

internal final class SQLiteZone: Zone {
    
    let rootDirectory: URL
    let fileExtension: String

    private let fileURL: URL
    private let database: SQLiteDatabase
    
    private let uncachableDataSizeLimit = 10000 // 10KB
    private let cache: Cache<Data> = .init()
    
    fileprivate let fileManager = FileManager()
    
    init(rootDirectory: URL, fileExtension: String) throws {
        let resolvedURL = rootDirectory.resolvingSymlinksInPath()
        self.rootDirectory = resolvedURL
        try? fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true, attributes: nil)
        self.fileExtension = fileExtension
        self.fileURL = resolvedURL.appendingPathComponent("zone").appendingPathExtension(fileExtension)
        database = try SQLiteDatabase(fileURL: self.fileURL)
        try database.setupForZone()
    }
    
    internal func dismantle() throws {
        try database.close()
    }
    
    private func cacheIfNeeded(_ data: Data, for reference: ZoneReference) {
        if data.count < uncachableDataSizeLimit {
            cache.setValue(data, for: reference)
        }
    }
    
    internal func store(_ data: Data, for reference: ZoneReference) throws {
        try database.store(data, for: reference)
        cacheIfNeeded(data, for: reference)
    }
    
    internal func data(for reference: ZoneReference) throws -> Data? {
        if let data = cache.value(for: reference) { return data }
        guard let data = try database.data(for: reference) else { return nil }
        cacheIfNeeded(data, for: reference)
        return data
    }
    
    internal func data(for references: [ZoneReference]) throws -> [Data?] {
        guard !references.isEmpty else { return [] }

        // Check cache first, collect uncached references with their indices
        var results = [Data?](repeating: nil, count: references.count)
        var uncached: [(index: Int, key: String, version: String)] = []
        for (i, ref) in references.enumerated() {
            if let data = cache.value(for: ref) {
                results[i] = data
            } else {
                uncached.append((index: i, key: ref.key, version: ref.version.rawValue))
            }
        }

        if !uncached.isEmpty {
            let tuples = uncached.map { (key: $0.key, version: $0.version) }
            let fetched = try database.data(forReferences: tuples)
            for (localIndex, entry) in uncached.enumerated() {
                if let data = fetched[localIndex] {
                    results[entry.index] = data
                    cacheIfNeeded(data, for: references[entry.index])
                }
            }
        }

        return results
    }

    internal func versionIds(for key: String) throws -> [Version.ID] {
        try database.versionIds(forKey: key).map { Version.ID($0) }
    }
}
