//
//  Map.swift
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
    private let nodeCache: Cache<Node> = .init()
    
    fileprivate let encoder = JSONEncoder()
    fileprivate let decoder = JSONDecoder()
    
    private let rootKey = "__llvs_root"
    
    init(zone: Zone) {
        self.zone = zone
    }
    
    func addVersion(_ version: Version.Identifier, basedOn baseVersion: Version.Identifier?, applying deltas: [Delta]) throws {
        var rootNode: Node
        let rootRef = ZoneReference(key: rootKey, version: version)
        if let baseVersion = baseVersion {
            let oldRootRef = ZoneReference(key: rootKey, version: baseVersion)
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
            let subNodeRef = ZoneReference(key: subNodeKey.keyString, version: version)
            var subNode: Node
            if let n = subNodesByKey[subNodeKey] {
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
            
            guard case let .values(keyValuePairs) = subNode.children else { throw Error.unexpectedNodeContent }
            
            let valueRefs = keyValuePairs.filter({ $0.key == key }).map({ $0.valueReference })
            var valueRefsByIdentifier: [Value.Identifier:Value.Reference] = Dictionary(uniqueKeysWithValues: valueRefs.map({ ($0.identifier, $0) }) )
            for valueRef in delta.addedValueReferences {
                valueRefsByIdentifier[valueRef.identifier] = valueRef
            }
            for valueIdentifier in delta.removedValueIdentifiers {
                valueRefsByIdentifier[valueIdentifier] = nil
            }
            let newValueRefs = Array(valueRefsByIdentifier.values)
            var newPairs = keyValuePairs.filter { $0.key != key }
            newPairs += newValueRefs.map { KeyValuePair(key: key, valueReference: $0) }
            subNode.children = .values(newPairs)
            
            subNodesByKey[subNodeKey] = subNode
        }
        
        // Update and save subnodes and rootnode
        var rootRefsByIdentifier: [String:ZoneReference] = Dictionary(uniqueKeysWithValues: rootChildRefs.map({ ($0.key, $0) }) )
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
    
    func differences(between firstVersion: Version.Identifier, and secondVersion: Version.Identifier, withCommonAncestor commonAncestor: Version.Identifier?) throws -> [Diff] {
        let originRef = commonAncestor.flatMap { ZoneReference(key: rootKey, version: $0) }
        let rootRef1 = ZoneReference(key: rootKey, version: firstVersion)
        let rootRef2 = ZoneReference(key: rootKey, version: secondVersion)
        
        let originNode = try originRef.flatMap { try node(for: $0) }
        guard
            let rootNode1 = try node(for: rootRef1),
            let rootNode2 = try node(for: rootRef2) else {
            throw Error.missingVersionRoot
        }

        let nodesOrigin: [ZoneReference]?
        if case let .nodes(n)? = originNode?.children {
            nodesOrigin = n
        } else {
            nodesOrigin = nil
        }
        guard
            case let .nodes(subNodes1) = rootNode1.children,
            case let .nodes(subNodes2) = rootNode2.children else {
            throw Error.unexpectedNodeContent
        }

        let refOriginByKey: [String:ZoneReference]? = nodesOrigin.flatMap { refs in .init(uniqueKeysWithValues: refs.map({ ($0.key, $0) })) }
        let subNodeRefs1ByKey: [String:ZoneReference] = .init(uniqueKeysWithValues: subNodes1.map({ ($0.key, $0) }))
        let subNodeRefs2ByKey: [String:ZoneReference] = .init(uniqueKeysWithValues: subNodes2.map({ ($0.key, $0) }))
        var allSubNodeKeys = Set(subNodeRefs1ByKey.keys).union(subNodeRefs2ByKey.keys)
        if let r = refOriginByKey { allSubNodeKeys.formUnion(r.keys) }
        
        var diffs: [Diff] = []
        for subNodeKey in allSubNodeKeys {
            
            func appendDiffs(forIdentifiers ids: [Value.Identifier], fork: Value.Fork) throws {
                for id in ids {
                    let diff = Diff(key: .init(subNodeKey), valueIdentifier: id, valueFork: fork)
                    diffs.append(diff)
                }
            }
            
            func appendDiffs(forSubNode subNodeRef: ZoneReference, fork: Value.Fork) throws {
                let refs = try valueReferences(forRootSubNode: subNodeRef)
                try appendDiffs(forIdentifiers: refs.map({ $0.identifier }), fork: fork)
            }
            
            func appendDiffs(forOriginNode originNode: ZoneReference, onlyBranchNode branchNode: ZoneReference, branch: Value.Fork.Branch) throws {
                let vo = try valueReferences(forRootSubNode: originNode)
                let vb = try valueReferences(forRootSubNode: branchNode)
                let refOById: [Value.Identifier:Value.Reference] = .init(uniqueKeysWithValues: vo.map({ ($0.identifier, $0) }))
                let refBById: [Value.Identifier:Value.Reference] = .init(uniqueKeysWithValues: vb.map({ ($0.identifier, $0) }))
                let allIds = Set(refOById.keys).union(refBById.keys)
                for valueId in allIds {
                    let refO = refOById[valueId]
                    let refB = refBById[valueId]
                    switch (refO, refB) {
                    case let (ro?, rb?):
                        if ro != rb {
                            try appendDiffs(forIdentifiers: [valueId], fork: .removedAndUpdated(removedOn: branch.opposite))
                        } else {
                            try appendDiffs(forIdentifiers: [valueId], fork: .removed(branch.opposite))
                        }
                    case (_?, nil):
                        try appendDiffs(forIdentifiers: [valueId], fork: .twiceRemoved)
                    case (nil, _?):
                        try appendDiffs(forIdentifiers: [valueId], fork: .inserted(branch))
                    case (nil, nil):
                        fatalError()
                    }
                }
            }
            
            let ref1 = subNodeRefs1ByKey[subNodeKey]
            let ref2 = subNodeRefs2ByKey[subNodeKey]
            let origin = refOriginByKey?[subNodeKey]
            switch (origin, ref1, ref2) {
            case let (o?, r1?, r2?):
                let vo = try valueReferences(forRootSubNode: o)
                let v1 = try valueReferences(forRootSubNode: r1)
                let v2 = try valueReferences(forRootSubNode: r2)
                let refOById: [Value.Identifier:Value.Reference] = .init(uniqueKeysWithValues: vo.map({ ($0.identifier, $0) }))
                let ref1ById: [Value.Identifier:Value.Reference] = .init(uniqueKeysWithValues: v1.map({ ($0.identifier, $0) }))
                let ref2ById: [Value.Identifier:Value.Reference] = .init(uniqueKeysWithValues: v2.map({ ($0.identifier, $0) }))
                let allIds = Set(refOById.keys).union(ref1ById.keys).union(ref2ById.keys)
                for valueId in allIds {
                    let refO = refOById[valueId]
                    let ref1 = ref1ById[valueId]
                    let ref2 = ref2ById[valueId]
                    switch (refO, ref1, ref2) {
                    case let (ro?, r1?, r2?):
                        if ro == r1, ro != r2 {
                            try appendDiffs(forIdentifiers: [valueId], fork: .updated(.second))
                        } else if ro != r1, ro == r2 {
                            try appendDiffs(forIdentifiers: [valueId], fork: .updated(.first))
                        } else if ro != r1, ro != r2 {
                            try appendDiffs(forIdentifiers: [valueId], fork: .twiceUpdated)
                        }
                    case let (ro?, r1?, nil):
                        if ro != r1 {
                            try appendDiffs(forIdentifiers: [valueId], fork: .removedAndUpdated(removedOn: .second))
                        } else {
                            try appendDiffs(forIdentifiers: [valueId], fork: .removed(.second))
                        }
                    case let (ro?, nil, r2?):
                        if ro != r2 {
                            try appendDiffs(forIdentifiers: [valueId], fork: .removedAndUpdated(removedOn: .first))
                        } else {
                            try appendDiffs(forIdentifiers: [valueId], fork: .removed(.first))
                        }
                    case (nil, _?, _?):
                        try appendDiffs(forIdentifiers: [valueId], fork: .twiceInserted)
                    case (nil, nil, _?):
                        try appendDiffs(forIdentifiers: [valueId], fork: .inserted(.second))
                    case (nil, _?, nil):
                        try appendDiffs(forIdentifiers: [valueId], fork: .inserted(.first))
                    case (_?, nil, nil):
                        try appendDiffs(forIdentifiers: [valueId], fork: .twiceRemoved)
                    case (nil, nil, nil):
                        fatalError()
                    }
                }
            case let (o?, r1?, nil):
                try appendDiffs(forOriginNode: o, onlyBranchNode: r1, branch: .first)
            case let (o?, nil, r2?):
                try appendDiffs(forOriginNode: o, onlyBranchNode: r2, branch: .second)
            case let (nil, r1?, r2?):
                let v1 = try valueReferences(forRootSubNode: r1)
                let v2 = try valueReferences(forRootSubNode: r2)
                let ref1ById: [Value.Identifier:Value.Reference] = .init(uniqueKeysWithValues: v1.map({ ($0.identifier, $0) }))
                let ref2ById: [Value.Identifier:Value.Reference] = .init(uniqueKeysWithValues: v2.map({ ($0.identifier, $0) }))
                let allIds = Set(ref1ById.keys).union(ref2ById.keys)
                for valueId in allIds {
                    let ref1 = ref1ById[valueId]
                    let ref2 = ref2ById[valueId]
                    switch (ref1, ref2) {
                    case (_?, _?):
                        try appendDiffs(forIdentifiers: [valueId], fork: .twiceInserted)
                    case (_?, nil):
                        try appendDiffs(forIdentifiers: [valueId], fork: .inserted(.first))
                    case (nil, _?):
                        try appendDiffs(forIdentifiers: [valueId], fork: .inserted(.second))
                    case (nil, nil):
                        fatalError()
                    }
                }
            case let (nil, r1?, nil):
                try appendDiffs(forSubNode: r1, fork: .inserted(.first))
            case let (nil, nil, r2?):
                try appendDiffs(forSubNode: r2, fork: .inserted(.second))
            case let (o?, nil, nil):
                try appendDiffs(forSubNode: o, fork: .twiceRemoved)
            case (nil, nil, nil):
                fatalError()
            }
        }

        return diffs
    }
    
    func enumerateValueReferences(forVersionIdentifiedBy versionId: Version.Identifier, executingForEach block: (Value.Reference) throws -> Void) throws {
        let rootRef = ZoneReference(key: rootKey, version: versionId)
        guard let rootNode = try node(for: rootRef) else { throw Error.missingVersionRoot }
        guard case let .nodes(subNodeRefs) = rootNode.children else { throw Error.missingNode }
        for subNodeRef in subNodeRefs {
            guard let subNode = try node(for: subNodeRef) else { throw Error.missingNode }
            guard case let .values(keyValuePairs) = subNode.children else { throw Error.unexpectedNodeContent }
            for keyValuePair in keyValuePairs {
                try block(keyValuePair.valueReference)
            }
        }
    }
    
    func valueReferences(matching key: Map.Key, at version: Version.Identifier) throws -> [Value.Reference] {
        let rootRef = ZoneReference(key: rootKey, version: version)
        guard let rootNode = try node(for: rootRef) else { throw Error.missingVersionRoot }
        guard case let .nodes(subNodeRefs) = rootNode.children else { throw Error.missingNode }
        let subNodeKey = String(key.keyString.prefix(2))
        guard let subNodeRef = subNodeRefs.first(where: { $0.key == subNodeKey }) else { return [] }
        guard let subNode = try node(for: subNodeRef) else { throw Error.missingNode }
        guard case let .values(keyValuePairs) = subNode.children else { throw Error.unexpectedNodeContent }
        return keyValuePairs.filter({ $0.key == key }).map({ $0.valueReference })
    }

    fileprivate func node(for key: String, version: Version.Identifier) throws -> Node? {
        let ref = ZoneReference(key: key, version: version)
        return try node(for: ref)
    }
    
    fileprivate func node(for reference: ZoneReference) throws -> Node? {
        if let node = nodeCache.value(for: reference) {
            return node
        } else if let data = try zone.data(for: reference) {
            let node = try decoder.decode(Node.self, from: data)
            nodeCache.setValue(node, for: reference)
            return node
        } else {
            return nil
        }
    }
    
    private func valueReferences(forRootSubNode subNodeRef: ZoneReference) throws -> [Value.Reference] {
        guard let subNode = try node(for: subNodeRef) else { throw Error.missingNode }
        guard case let .values(keyValuePairs) = subNode.children else { throw Error.unexpectedNodeContent }
        return keyValuePairs.map({ $0.valueReference })
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
    
    struct Diff {
        var key: Key
        var valueIdentifier: Value.Identifier
        var valueFork: Value.Fork
    }
    
    struct KeyValuePair: Codable, Hashable {
        var key: Key
        var valueReference: Value.Reference
    }
    
    struct Delta {
        var key: Key
        var addedValueReferences: [Value.Reference] = []
        var removedValueIdentifiers: [Value.Identifier] = []
        
        init(key: Key) {
            self.key = key
        }
    }
    
    struct Node: Codable, Hashable {
        var reference: ZoneReference
        var children: Children
    }
    
    enum Children: Codable, Hashable {
        case values([KeyValuePair])
        case nodes([ZoneReference])
        
        enum Key: CodingKey {
            case values
            case nodes
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            if let values = try? container.decode([KeyValuePair].self, forKey: .values) {
                self = .values(values)
            } else if let nodes = try? container.decode([ZoneReference].self, forKey: .nodes) {
                self = .nodes(nodes)
            } else {
                throw Error.encodingFailure("No valid references found in decoder")
            }
        }
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            switch self {
            case let .values(values):
                try container.encode(values, forKey: .values)
            case let .nodes(nodes):
                try container.encode(nodes, forKey: .nodes)
            }
        }
    }
    
}
