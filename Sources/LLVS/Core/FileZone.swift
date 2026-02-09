//
//  FileZone.swift
//  LLVS
//
//  Created by Drew McCormack on 14/05/2019.
//

import Foundation

public class FileStorage: Storage, SnapshotCapable {

    private let fileExtension = "json"

    public init() {}

    public func makeMapZone(for type: MapType, in store: Store) -> Zone {
        switch type {
        case .valuesByVersion:
            return FileZone(rootDirectory: store.valuesMapDirectoryURL, fileExtension: fileExtension)
        case .userDefined:
            fatalError("User defined maps not yet supported")
        }
    }

    public func makeValuesZone(in store: Store) -> Zone {
        return FileZone(rootDirectory: store.valuesDirectoryURL, fileExtension: fileExtension)
    }

    // MARK: SnapshotCapable

    public var snapshotFormat: String { "fileStorage-v1" }

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

            // If adding this entry would exceed maxChunkSize, flush first
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
                // Read path length (little-endian UInt32, alignment-safe)
                guard offset + 4 <= chunkData.count else { break }
                let pathLen = Self.readUInt32(from: chunkData, at: offset)
                offset += 4

                // Read path
                guard offset + Int(pathLen) <= chunkData.count else { break }
                let pathData = chunkData[offset..<offset+Int(pathLen)]
                let relativePath = String(data: pathData, encoding: .utf8)!
                offset += Int(pathLen)

                // Read data length
                guard offset + 4 <= chunkData.count else { break }
                let dataLen = Self.readUInt32(from: chunkData, at: offset)
                offset += 4

                // Read data
                guard offset + Int(dataLen) <= chunkData.count else { break }
                let fileData = chunkData[offset..<offset+Int(dataLen)]
                offset += Int(dataLen)

                // Write file
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

internal final class FileZone: Zone {
    
    let rootDirectory: URL
    let fileExtension: String
    
    private let uncachableDataSizeLimit = 10000 // 10KB
    private let cache: Cache<Data> = .init()
    
    fileprivate let fileManager = FileManager()
    
    init(rootDirectory: URL, fileExtension: String) {
        self.rootDirectory = rootDirectory.resolvingSymlinksInPath()
        try? fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true, attributes: nil)
        self.fileExtension = fileExtension
    }
    
    private func cacheIfNeeded(_ data: Data, for reference: ZoneReference) {
        if data.count < uncachableDataSizeLimit {
            cache.setValue(data, for: reference)
        }
    }
    
    internal func store(_ data: Data, for reference: ZoneReference) throws {
        let (dir, file) = try fileSystemLocation(for: reference)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        try data.write(to: file)
        cacheIfNeeded(data, for: reference)
    }
    
    internal func data(for reference: ZoneReference) throws -> Data? {
        if let data = cache.value(for: reference) { return data }
        let (_, file) = try fileSystemLocation(for: reference)
        guard let data = try? Data(contentsOf: file) else { return nil }
        cacheIfNeeded(data, for: reference)
        return data
    }
    
    func fileSystemLocation(for reference: ZoneReference) throws -> (directoryURL: URL, fileURL: URL) {
        let safeKey = reference.key.replacingOccurrences(of: "/", with: "LLVSSLASH").replacingOccurrences(of: ":", with: "LLVSCOLON")
        let valueDirectoryURL = rootDirectory.appendingSplitPathComponent(safeKey)
        let versionName = reference.version.rawValue + "." + fileExtension
        let fileURL = valueDirectoryURL.appendingSplitPathComponent(versionName, prefixLength: 1)
        let directoryURL = fileURL.deletingLastPathComponent()
        return (directoryURL: directoryURL, fileURL: fileURL)
    }
    
    internal func versionIds(for key: String) throws -> [Version.ID] {
        let valueDirectoryURL = rootDirectory.appendingSplitPathComponent(key)
        let valueDirLength = valueDirectoryURL.path.count
        let enumerator = fileManager.enumerator(at: valueDirectoryURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])!
        var versions: [Version.ID] = []
        let slash = Character("/")
        for any in enumerator {
            var isDirectory: ObjCBool = true
            guard let url = any as? URL else { continue }
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue else { continue }
            let path = url.resolvingSymlinksInPath().deletingPathExtension().path
            let index = path.index(path.startIndex, offsetBy: Int(valueDirLength))
            let version = String(path[index...]).filter { $0 != slash }
            versions.append(Version.ID(version))
        }
        return versions
    }
}
