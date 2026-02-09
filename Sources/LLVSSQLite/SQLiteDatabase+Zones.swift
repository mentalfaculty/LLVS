//
//  SQLiteDatabase+Zones.swift
//  
//
//  Created by Drew McCormack on 16/02/2022.
//

import Foundation
import LLVS

internal extension SQLiteDatabase {
    
    func setupForZone() throws {
        try execute(statement:
            """
            CREATE TABLE IF NOT EXISTS
                Zone(
                    key TEXT NOT NULL,
                    version TEXT NOT NULL,
                    data BLOB NOT NULL,
                    PRIMARY KEY (key, version)
                );
            """
        )
        try execute(statement:
            """
            CREATE INDEX IF NOT EXISTS index_key ON Zone (key);
            """
        )
        try execute(statement:
            """
            CREATE INDEX IF NOT EXISTS index_version ON Zone (version);
            """
        )
    }
    
    func store(_ data: Data, for reference: ZoneReference) throws {
        try execute(statement:
            """
            INSERT OR REPLACE INTO Zone (key, version, data) VALUES (?, ?, ?);
            """,
            withBindingsList: [[reference.key, reference.version.rawValue, data]])
    }
    
    func data(for reference: ZoneReference) throws -> Data? {
        var result: Data?
        try forEach(matchingQuery:
            """
            SELECT data FROM Zone WHERE key=? AND version=?;
            """,
            withBindings: [reference.key, reference.version.rawValue]) { row in
                result = row.value(inColumnAtIndex: 0)
            }
        return result
    }
    
    func data(forReferences references: [(key: String, version: String)]) throws -> [Int: Data] {
        guard !references.isEmpty else { return [:] }

        // Group references by version, tracking original indices
        var indicesByVersion: [String: [(index: Int, key: String)]] = [:]
        for (i, ref) in references.enumerated() {
            indicesByVersion[ref.version, default: []].append((index: i, key: ref.key))
        }

        var result: [Int: Data] = [:]

        // One query per distinct version
        for (version, entries) in indicesByVersion {
            let placeholders = entries.map { _ in "?" }.joined(separator: ", ")
            let query = "SELECT key, data FROM Zone WHERE version = ? AND key IN (\(placeholders));"
            var bindings: [Any?] = [version]
            bindings.append(contentsOf: entries.map { $0.key as Any? })

            // Build lookup from key to indices (multiple refs can share a key within the same version)
            var indexByKey: [String: [Int]] = [:]
            for entry in entries {
                indexByKey[entry.key, default: []].append(entry.index)
            }

            try forEach(matchingQuery: query, withBindings: bindings) { row in
                let key: String = row.value(inColumnAtIndex: 0)!
                let data: Data = row.value(inColumnAtIndex: 1)!
                if let indices = indexByKey[key] {
                    for index in indices {
                        result[index] = data
                    }
                }
            }
        }

        return result
    }

    func versionIds(forKey key: String) throws -> [String] {
        var versionStrings: [String] = []
        try forEach(matchingQuery:
            """
            SELECT DISTINCT version FROM Zone WHERE key=?;
            """,
            withBindings: [key]) { row in
                let versionId: String = row.value(inColumnAtIndex: 0)!
                versionStrings.append(versionId)
            }
        return versionStrings
    }
    
}
