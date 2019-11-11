//
//  Version.swift
//  llvs
//
//  Created by Drew McCormack on 31/10/2018.
//

import Foundation

public struct Version: Hashable, Identifiable {
    public typealias ID = Identifier

    public var id: ID = .init()
    public var predecessors: Predecessors?
    public var successors: Successors = .init()
    public var timestamp: TimeInterval
    public var metadata: Data?
    
    private enum CodingKeys: String, CodingKey {
        case identifier
        case predecessors
        case timestamp
        case metadata
    }
    
    public init(id: ID = .init(), predecessors: Predecessors? = nil, metadata: Data? = nil) {
        self.id = id
        self.predecessors = predecessors
        self.timestamp = Date().timeIntervalSinceReferenceDate
        self.metadata = metadata
    }
}


extension Version: Codable {
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ID.self, forKey: .identifier)
        predecessors = try container.decodeIfPresent(Predecessors.self, forKey: .predecessors)
        timestamp = try container.decode(TimeInterval.self, forKey: .timestamp)
        metadata = try container.decodeIfPresent(Data.self, forKey: .metadata)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .identifier)
        try container.encodeIfPresent(predecessors, forKey: .predecessors)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(metadata, forKey: .metadata)
    }
    
}


extension Version {
    
    public struct Identifier: RawRepresentable, Codable, Hashable {
        public var rawValue: String
        
        public init(rawValue: String = UUID().uuidString) {
            self.rawValue = rawValue
        }
        
        public init(_ rawValue: String) {
            self.init(rawValue: rawValue)
        }
    }
    
    public struct Predecessors: Codable, Hashable {
        public internal(set) var idOfFirst: ID
        public internal(set) var idOfSecond: ID?
        public var ids: [ID] {
            var result = [idOfFirst]
            if let second = idOfSecond { result.append(second) }
            return result
        }
        
        internal init(idOfFirst: ID, idOfSecond: ID?) {
            self.idOfFirst = idOfFirst
            self.idOfSecond = idOfSecond
        }
    }
    
    public struct Successors: Codable, Hashable {
        public internal(set) var ids: Set<ID>
        internal init(ids: Set<ID> = []) {
            self.ids = ids
        }
    }

}


public extension Collection where Element == Version {
    
    var ids: [Version.ID] {
        return map { $0.id }
    }
    
    var idStrings: [String] {
        return map { $0.id.rawValue }
    }
    
}


public extension Collection where Element == Version.ID {

    var idStrings: [String] {
        return map { $0.rawValue }
    }
    
}
