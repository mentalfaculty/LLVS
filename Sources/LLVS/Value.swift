//
//  JSON.swift
//  llvs
//
//  Created by Drew McCormack on 31/10/2018.
//

import Foundation


public struct Value {
    
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


public extension Value {
    
    public struct Reference: Codable, Hashable {
        var identifier: Identifier
        var version: Version.Identifier
    }
    
    public struct Identifier: StringIdentifiable, Hashable, Codable {
        public var identifierString: String
        
        public init(_ identifierString: String = UUID().uuidString) {
            self.identifierString = identifierString
        }
    }
    
    public enum Change {
        case insert(Value)
        case update(Value)
        case remove(Identifier)
        case preserve(Reference)
    }
    
    public enum Fork {
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
        case removedAndUpdated(removedOn: Branch)
        
        public var conflicting: Bool {
            switch self {
            case .inserted, .removed, .updated, .twiceRemoved:
                return false
            case .twiceInserted, .twiceUpdated, .removedAndUpdated:
                return true
            }
        }
    }
}
