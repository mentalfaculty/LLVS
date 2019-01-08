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
        case preserveRemoval(Identifier)
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
        
        public var isConflicting: Bool {
            switch self {
            case .inserted, .removed, .updated, .twiceRemoved:
                return false
            case .twiceInserted, .twiceUpdated, .removedAndUpdated:
                return true
            }
        }
    }
}


extension Array where Element == Value.Change {
    
    var valueIdentifiers: [Value.Identifier] {
        return self.map { change in
            switch change {
            case .insert(let value), .update(let value):
                return value.identifier
            case .remove(let identifier), .preserveRemoval(let identifier):
                return identifier
            case .preserve(let ref):
                return ref.identifier
            }
        }
    }
    
}
