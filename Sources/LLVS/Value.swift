//
//  JSON.swift
//  llvs
//
//  Created by Drew McCormack on 31/10/2018.
//

import Foundation

public struct VersionedValue {
    public var value: Value
    public var version: Version
}

public struct Value {
    
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
    
    public enum Diff {
        public enum Branch {
            case first
            case second
        }
        
        case inserted(Branch)
        case twiceInserted
        case removed(Branch)
        case twiceRemoved
        case updated(Branch)
        case twiceUpdated
        case removedAndUpdated(removedOn: Branch, updatedOn: Branch)
        
        public var conflicting: Bool {
            switch self {
            case .inserted, .removed, .updated:
                return false
            case .twiceInserted, .twiceRemoved, .twiceUpdated, .removedAndUpdated:
                return true
            }
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
