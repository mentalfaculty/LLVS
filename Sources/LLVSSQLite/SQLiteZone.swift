//
//  SQLiteZone.swift
//  LLVS
//
//  Created by Drew McCormack on 14/05/2019.
//

import Foundation
import LLVS
import SQLite3

public class SQLiteStorage: Storage {
    
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

    internal func delete(for reference: ZoneReference) throws {
        cache.removeValue(for: reference)
        try database.delete(for: reference)
    }

    internal func deleteAll(forVersionIdentifiedBy version: Version.ID) throws {
        cache.purgeAllValues()
        try database.deleteAll(forVersionIdentifiedBy: version.rawValue)
    }

    internal func versionIds(for key: String) throws -> [Version.ID] {
        try database.versionIds(forKey: key).map { Version.ID($0) }
    }
}
