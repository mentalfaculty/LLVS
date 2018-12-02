//
//  JSON.swift
//  llvs
//
//  Created by Drew McCormack on 31/10/2018.
//

import Foundation

public struct Value: Codable {
    
    struct Diff {
        let firstValue: Value
        let secondValue: Value
    }
    
    struct Reference: Codable, Hashable {
        var identifier: Identifier
        var version: Version
    }
    
    public struct Identifier: StringIdentifiable, Hashable, Codable {
        public var identifierString: String = UUID().uuidString
    }
    
    var identifier: Identifier
    var version: Version?
    var properties: [String:String] = [:]
    
    var zoneReference: Zone.Reference? {
        guard let version = version else { return nil }
        return Zone.Reference(key: identifier.identifierString, version: version.identifier)
    }
    
}
