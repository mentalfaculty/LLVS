//
//  FilterMap.swift
//  LLVS
//
//  Created by Drew McCormack on 30/11/2018.
//

import Foundation


final class Map {
    
    enum Error: Swift.Error {
        case encodingFailure(String)
        case unexpectedNodeContent
        case missingNode
        case missingVersionRoot
    }
        
    let zone: Zone
    
    fileprivate let encoder = JSONEncoder()
    fileprivate let decoder = JSONDecoder()
    
    private let rootKey = "__llvs_root"
    
    init(zone: Zone) {
        self.zone = zone
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
        
        var subNodesByKey: [Key:Node] = [:]
        for delta in deltas {
            let key = delta.key
            let subNodeKey = Key(String(key.keyString.prefix(2)))
            let subNodeRef = Zone.Reference(key: subNodeKey.keyString, version: version)
            var subNode: Node
            if let n = subNodesByKey[key] {
                subNode = n
            }
            else if let existingSubNodeRef = rootChildRefs.first(where: { $0.key == subNodeKey.keyString }) {
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
    
    func differences(between firstVersion: Version.Identifier, and secondVersion: Version.Identifier, withCommonAncestor commonAncestor: Version.Identifier) throws -> [Diff] {
        return []
    }
    
    func valueReferences(matching key: Map.Key, at version: Version.Identifier) throws -> [Value.Reference] {
        let rootRef = Zone.Reference(key: rootKey, version: version)
        guard let rootNode = try node(for: rootRef) else { throw Error.missingVersionRoot }
        guard case let .nodes(subNodeRefs) = rootNode.children else { throw Error.missingNode }
        let subNodeKey = String(key.keyString.prefix(2))
        guard let subNodeRef = subNodeRefs.first(where: { $0.key == subNodeKey }) else { return [] }
        guard let subNode = try node(for: subNodeRef) else { throw Error.missingNode }
        guard case let .values(valueRefs) = subNode.children else { throw Error.unexpectedNodeContent }
        return valueRefs
    }

    fileprivate func node(for key: String, version: Version.Identifier) throws -> Node? {
        let ref = Zone.Reference(key: key, version: version)
        return try node(for: ref)
    }
    
    fileprivate func node(for reference: Zone.Reference) throws -> Node? {
        guard let data = try zone.data(for: reference) else { return nil }
        return try decoder.decode(Node.self, from: data)
    }
    
}


// MARK:- Subtypes

extension Map {
    
    struct Key: Codable, Hashable {
        var keyString: String
        init(_ keyString: String = UUID().uuidString) {
            self.keyString = keyString
        }
    }
    
    struct Delta {
        var key: Key
        var addedValueIdentifiers: [Value.Identifier] = []
        var removedValueIdentifiers: [Value.Identifier] = []
        
        init(key: Key) {
            self.key = key
        }
    }
    
    struct Diff {
        enum Branch {
            case first
            case second
        }
        
        enum Fork {
            case inserted(branch: Branch)
            case twiceInserted
            case removed(branch: Branch)
            case twiceRemoved
            case updated(branch: Branch)
            case twiceUpdated
            case removedAndUpdated(removedOn: Branch, updatedOn: Branch)
        }
        
        var key: Key
        var valueIdentifier: Value.Identifier
        var fork: Fork
    }
    
    struct Node: Codable, Hashable {
        var reference: Zone.Reference
        var children: Children
    }
    
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
