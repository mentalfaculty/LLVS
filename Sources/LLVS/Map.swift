//
//  FilterMap.swift
//  LLVS
//
//  Created by Drew McCormack on 30/11/2018.
//

import Foundation


final class Map {
    
    struct Delta {
        var key: String
        var addedValueIdentifiers: [Value.Identifier]
        var removedValueIdentifiers: [Value.Identifier]
    }
    
    enum Error: Swift.Error {
        case encodingFailure(String)
        case unexpectedNodeContent
        case missingNode
    }
        
    let zone: Zone
    let root: Key
    
    fileprivate let encoder = JSONEncoder()
    fileprivate let decoder = JSONDecoder()
    
    init(zone: Zone, root: Key) {
        self.zone = zone
        self.root = root
    }
    
    func addVersion(_ version: Version.Identifier, basedOn baseVersion: Version.Identifier?, applying deltas: [Delta]) throws {
        var rootNode: Node
        let rootRef = Zone.Reference(key: rootKey, version: version)
        if let baseVersion = baseVersion {
            let oldRootRef = Zone.Reference(key: rootKey, version: baseVersion)
            guard let oldRoot = try node(for: oldRootRef) else { throw Error.missingNode }
            rootNode = oldRoot
        }
        else {
            rootNode = Node(reference: rootRef, children: .nodes([]))
        }
        rootNode.reference.version = version
        guard case let .nodes(rootChildRefs) = rootNode.children else { throw Error.unexpectedNodeContent }
        
        var subNodesByKey: [String:Node] = [:]
        for delta in deltas {
            let key = delta.key
            let subNodeKey = String(key.prefix(2))
            let subNodeRef = Zone.Reference(key: subNodeKey, version: version)
            var subNode: Node
            if let n = subNodesByKey[key] {
                subNode = n
            }
            else if let existingSubNodeRef = rootChildRefs.first(where: { $0.key == subNodeKey }) {
                guard let existingSubNode = try node(for: existingSubNodeRef) else { throw Error.missingNode }
                subNode = existingSubNode
                subNode.reference = subNodeRef
            }
            else {
                subNode = Node(reference: subNodeRef, children: .values([]))
            }
            
            guard case let .values(valueRefs) = subNode.children else { throw Error.unexpectedNodeContent }
            var valueRefsByIdentifier: [Value.Identifier:Value.Reference] = Dictionary(uniqueKeysWithValues: valueRefs.map({ ($0.identifier, $0) }) )
            for valueIdentifier in delta.addedValueIdentifiers {
                valueRefsByIdentifier[valueIdentifier] = Value.Reference(identifier: valueIdentifier, version: version)
            }
            for valueIdentifier in delta.removedValueIdentifiers {
                valueRefsByIdentifier[valueIdentifier] = nil
            }
            let newValueRefs = Array(valueRefsByIdentifier.values)
            subNode.children = .values(newValueRefs)
            
            subNodesByKey[key] = subNode
        }
        
        // Update and save subnodes and rootnode
        var rootRefsByIdentifier: [String:Zone.Reference] = Dictionary(uniqueKeysWithValues: rootChildRefs.map({ ($0.key, $0) }) )
        for subNode in subNodesByKey.values {
            let key = subNode.reference.key
            let data = try encoder.encode(subNode)
            try zone.store(data, for: subNode.reference)
            rootRefsByIdentifier[key] = subNode.reference
        }
        rootNode.children = .nodes(Array(rootRefsByIdentifier.values))
        let data = try encoder.encode(rootNode)
        try zone.store(data, for: rootNode.reference)
    }
    
    func valueReferences(matching key: Map.Key) throws -> [Value.Reference] {
        return []
    }
    
    func valueIdentifiers(whereValuesDifferBetween version: Version, and otherVersion: Version) -> [Value.Identifier] {
        return []
    }
    
    private let rootKey = "__llvs_root"
    
//    fileprivate func existingNodalPath(for key: String, withRootVersion rootVersion: Version.Identifier) throws -> [Node] {
//        guard let rootNode = try node(for: rootKey, version: rootVersion) else { return [] }
//        guard case let .nodes(refs) = rootNode.children else { throw Error.unexpectedNodeContent }
//
//        let subNodeKey = key.prefix(2)
//        guard let subNodeRef = refs.first(where: { $0.key == subNodeKey }), let subNode = try node(for: subNodeRef) else {
//            return [rootNode]
//        }
//
//        return [rootNode, subNode]
//    }
    

    fileprivate func node(for key: String, version: Version.Identifier) throws -> Node? {
        let ref = Zone.Reference(key: key, version: version)
        return try node(for: ref)
    }
    
    fileprivate func node(for reference: Zone.Reference) throws -> Node? {
        guard let data = try zone.data(for: reference) else { return nil }
        return try decoder.decode(Node.self, from: data)
    }
    
}


extension Map {
    
    struct Key: Codable, Hashable {
        public var keyString: String = UUID().uuidString
    }
    
    struct Node: Codable, Hashable {
        var reference: Zone.Reference
        var children: Children
    }
    
}


extension Map {
    
    enum Children: Codable, Hashable {
        case values([Value.Reference])
        case nodes([Zone.Reference])
        
        enum Keys: CodingKey {
            case values
            case nodes
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            if let values = try? container.decode([Value.Reference].self, forKey: .values) {
                self = .values(values)
            } else if let nodes = try? container.decode([Zone.Reference].self, forKey: .nodes) {
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