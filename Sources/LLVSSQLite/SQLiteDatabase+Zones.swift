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
            CREATE INDEX index_key ON Zone (key);
            """
        )
        try execute(statement:
            """
            CREATE INDEX index_version ON Zone (version);
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
