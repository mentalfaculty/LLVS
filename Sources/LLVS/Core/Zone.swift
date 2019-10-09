//
//  Zone.swift
//  LLVS
//
//  Created by Drew McCormack on 02/12/2018.
//

import Foundation

public struct ZoneReference: Codable, Hashable {
    var key: String
    var version: Version.ID
}

public protocol Zone {
    func store(_ data: Data, for reference: ZoneReference) throws
    
    // Default provided, but zone implementations can optimize this.
    func store(_ data: [Data], for references: [ZoneReference]) throws

    func data(for reference: ZoneReference) throws -> Data?
    
    // Default provided, but zone implementations can optimize this.
    func data(for references: [ZoneReference]) throws -> [Data?]
}

public extension Zone {
    
    func store(_ data: [Data], for references: [ZoneReference]) throws {
        try zip(data, references).forEach { data, ref in
            try store(data, for: ref)
        }
    }
    
    func data(for references: [ZoneReference]) throws -> [Data?] {
        return try references.map { try data(for: $0) }
    }
    
}
