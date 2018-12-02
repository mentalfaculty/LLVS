//
//  FilterMap.swift
//  LLVS
//
//  Created by Drew McCormack on 30/11/2018.
//

import Foundation


final class Map {
    
    enum Delta {
        case include(Key, [Value.Identifier])
        case exclude(Key, [Value.Identifier])
    }
    
    enum Error: Swift.Error {
        case encodingFailure(String)
        case noStorageAvailable
    }
        
    let zone: Zone
    
    private let root: Key
    
    init(zone: Zone, root: Key) {
        self.zone = zone
        self.root = root
    }
    
    func addVersion(_ newVersion: Version, basedOn version: Version, applying deltas: [Delta]) {
        
    }
    
    func valueReferences(matching key: Map.Key) throws -> [Value.Reference] {
        return []
    }
    
    func valueIdentifiers(whereValuesDifferBetween version: Version, and otherVersion: Version) -> [Value.Identifier] {
        return []
    }
    
}


extension Map {
    
    struct Key: Codable, Hashable {
        public var keyString: String = UUID().uuidString
    }
    
    struct Node: Codable, Hashable {
        struct Reference: Codable, Hashable {
            var key: Key
            var version: Version
        }
        
        var reference: Reference
        var children: Children
    }
    
}


extension Map {
    
    enum Children: Codable, Hashable {
        case values([Value.Reference])
        case nodes([Node.Reference])
        
        enum Keys: CodingKey {
            case values
            case nodes
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            if let values = try? container.decode([Value.Reference].self, forKey: .values) {
                self = .values(values)
            } else if let nodes = try? container.decode([Node.Reference].self, forKey: .nodes) {
                self = .nodes(nodes)
            } else {
                throw Error.encodingFailure("No valid references found in decoder")
            }
        }
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            switch self {
            case let .values(values):
                try container.encode(values, forKey: .values)
            case let .nodes(nodes):
                try container.encode(nodes, forKey: .nodes)
            }
        }
    }
    
}
