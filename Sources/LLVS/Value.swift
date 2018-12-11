//
//  JSON.swift
//  llvs
//
//  Created by Drew McCormack on 31/10/2018.
//

import Foundation

public struct Value {
    
    struct Diff {
        let firstValue: Value
        let secondValue: Value
    }
    
    struct Reference: Codable, Hashable {
        var identifier: Identifier
        var version: Version.Identifier
    }
    
    public struct Identifier: StringIdentifiable, Hashable, Codable {
        public var identifierString: String
        
        public init(_ identifierString: String = UUID().uuidString) {
            self.identifierString = identifierString
        }
    }
    
    var identifier: Identifier
    var version: Version.Identifier?
    var data: Data
    
    var zoneReference: Zone.Reference? {
        guard let version = version else { return nil }
        return Zone.Reference(key: identifier.identifierString, version: version)
    }
    
    public init(identifier: Identifier, version: Version.Identifier?, data: Data) {
        self.identifier = identifier
        self.version = version
        self.data = data
    }
    
}
