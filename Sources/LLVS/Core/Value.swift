//
//  Value.swift
//  LLVS
//
//  Created by Drew McCormack on 31/10/2018.
//

import Foundation

public struct Value: Codable, Identifiable {
    public typealias ID = Identifier
    
    public var id: ID
    public var data: Data
    
    /// The identifier of the version in which this value was stored. Can be nil, if
    /// a value has not yet been stored.
    public internal(set) var storedVersionId: Version.ID?
    
    internal var zoneReference: ZoneReference? {
        guard let version = storedVersionId else { return nil }
        return ZoneReference(key: id.stringValue, version: version)
    }
    
    public var reference: Reference? {
        guard let version = storedVersionId else { return nil }
        return Reference(valueId: id, storedVersionId: version)
    }
    
    /// Convenience that saves creating IDs
    public init(idString: String, data: Data) {
        self.init(id: ID(idString), data: data)
    }
    
    /// If an id is not provided, a UUID will be used. The storedVersionId will be set to nil, because
    /// this value has not been stored yet.
    public init(id: ID = .init(UUID().uuidString), data: Data) {
        self.id = id
        self.data = data
    }
    
    internal init(id: ID, storedVersionId: Version.ID, data: Data) {
        self.id = id
        self.storedVersionId = storedVersionId
        self.data = data
    }
}


public extension Value {
    
    struct Reference: Codable, Hashable {
        public var valueId: ID
        public var storedVersionId: Version.ID
    }
    
    struct Identifier: StringIdentifiable, Hashable, Codable {
        public var stringValue: String
        
        public init(_ stringValue: String = UUID().uuidString) {
            self.stringValue = stringValue
        }
    }
    
    enum Change: Codable {
        case insert(Value)
        case update(Value)
        case remove(ID)
        case preserve(Reference)
        case preserveRemoval(ID)
        
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
            if let i = try? c.decode(ID.self, forKey: .remove) {
                self = .remove(i); return
            }
            if let r = try? c.decode(Reference.self, forKey: .preserve) {
                self = .preserve(r); return
            }
            if let i = try? c.decode(ID.self, forKey: .preserveRemoval) {
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
    
    var valueIds: [Value.ID] {
        return self.map { change in
            switch change {
            case .insert(let value), .update(let value):
                return value.id
            case .remove(let identifier), .preserveRemoval(let identifier):
                return identifier
            case .preserve(let ref):
                return ref.valueId
            }
        }
    }
    
}
