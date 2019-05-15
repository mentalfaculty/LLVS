//
//  Value.swift
//  LLVS
//
//  Created by Drew McCormack on 31/10/2018.
//

import Foundation


public struct Value: Codable {
    
    public var identifier: Identifier
    public var version: Version.Identifier?
    public var data: Data
    
    internal var zoneReference: ZoneReference? {
        guard let version = version else { return nil }
        return ZoneReference(key: identifier.identifierString, version: version)
    }
    
    public var reference: Reference? {
        guard let version = version else { return nil }
        return Reference(identifier: identifier, version: version)
    }
    
    public init(identifier: Identifier, version: Version.Identifier?, data: Data) {
        self.identifier = identifier
        self.version = version
        self.data = data
    }

}


public extension Value {
    
    struct Reference: Codable, Hashable {
        public var identifier: Identifier
        public var version: Version.Identifier
    }
    
    struct Identifier: StringIdentifiable, Hashable, Codable {
        public var identifierString: String
        
        public init(_ identifierString: String = UUID().uuidString) {
            self.identifierString = identifierString
        }
    }
    
    enum Change: Codable {
        case insert(Value)
        case update(Value)
        case remove(Identifier)
        case preserve(Reference)
        case preserveRemoval(Identifier)
        
        enum CodingKeys: String, CodingKey {
            case insert, update, remove, preserve, preserveRemoval
        }
        
        enum Error: Swift.Error {
            case changeDecodingFailure
        }
        
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .insert(value):
                try c.encode(value, forKey: .insert)
            case let .update(value):
                try c.encode(value, forKey: .update)
            case let .remove(id):
                try c.encode(id, forKey: .remove)
            case let .preserve(ref):
                try c.encode(ref, forKey: .preserve)
            case let .preserveRemoval(id):
                try c.encode(id, forKey: .preserveRemoval)
            }
        }
        
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let v = try? c.decode(Value.self, forKey: .insert) {
                self = .insert(v); return
            }
            if let v = try? c.decode(Value.self, forKey: .update) {
                self = .update(v); return
            }
            if let i = try? c.decode(Identifier.self, forKey: .remove) {
                self = .remove(i); return
            }
            if let r = try? c.decode(Reference.self, forKey: .preserve) {
                self = .preserve(r); return
            }
            if let i = try? c.decode(Identifier.self, forKey: .preserveRemoval) {
                self = .preserveRemoval(i); return
            }
            throw Error.changeDecodingFailure
        }
    }
    
    enum Fork: Equatable {
        public enum Branch: Equatable {
            case first
            case second
            
            var opposite: Branch {
                return self == .first ? .second : .first
            }
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
