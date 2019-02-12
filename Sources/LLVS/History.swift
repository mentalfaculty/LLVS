//
//  History.swift
//  LLVS
//
//  Created by Drew McCormack on 11/11/2018.
//

import Foundation

public class History {
    
    public enum Error: Swift.Error {
        case attemptToAddPreexistingVersion(identifier: String)
        case nonExistentVersionEncountered(identifier: String)
    }
    
    private var versionsByIdentifier: [Version.Identifier:Version] = [:]
    private var referencedVersionIdentifiers: Set<Version.Identifier> = [] // Any version that is a predecessor
    public private(set) var headIdentifiers: Set<Version.Identifier> = []  // Versions that are not predecessors of other versions
    
    public var mostRecentHead: Version? {
        let maxId = headIdentifiers.max { (vId1, vId2) -> Bool in
            let v1 = version(identifiedBy: vId1)!
            let v2 = version(identifiedBy: vId2)!
            return v1.timestamp < v2.timestamp
        }
        return maxId.flatMap { version(identifiedBy: $0) }
    }
    
    public func version(identifiedBy identifier: Version.Identifier) -> Version? {
        return versionsByIdentifier[identifier]
    }
    
    internal func version(prevailingFromCandidates candidates: [Version.Identifier], at versionIdentifier: Version.Identifier) -> Version? {
        if let candidate = candidates.first(where: { $0 == versionIdentifier }) {
            return version(identifiedBy: candidate)
        }
        
        var ancestors: Set<Version.Identifier> = [versionIdentifier]
        for v in self {
            // See if v is in our ancestry. If so, extend ancestry.
            if ancestors.contains(v.identifier) {
                ancestors.formUnion(v.predecessors?.identifiers ?? [])
                ancestors.remove(v.identifier)
            }
            
            if let candidate = candidates.first(where: { ancestors.contains($0) }) {
                return version(identifiedBy: candidate)
            }
        }
        
        return nil
    }
    
    /// If updatingPredecessorVersions is true, the successors of other versions may be updated.
    /// Use this when adding a new head when storing.
    /// Pass in false if more control is needed over setting the successors, such as
    /// when loading them to setup the History. In that case, we only want to set them when all versions
    /// have been loaded.
    internal func add(_ version: Version, updatingPredecessorVersions: Bool) throws {
        guard versionsByIdentifier[version.identifier] == nil else {
            throw Error.attemptToAddPreexistingVersion(identifier: version.identifier.identifierString)
        }
        
        versionsByIdentifier[version.identifier] = version
        if updatingPredecessorVersions {
            try updateSuccessors(inPredecessorsOf: version)
        }
        
        if !referencedVersionIdentifiers.contains(version.identifier) {
            headIdentifiers.insert(version.identifier)
        }
    }
    
    internal func updateSuccessors(inPredecessorsOf version: Version) throws {
        for predecessorIdentifier in version.predecessors?.identifiers ?? [] {
            guard let predecessor = self.version(identifiedBy: predecessorIdentifier) else {
                throw Error.nonExistentVersionEncountered(identifier: predecessorIdentifier.identifierString)
            }
            
            referencedVersionIdentifiers.insert(predecessorIdentifier)
            headIdentifiers.remove(predecessorIdentifier)
            
            var newPredecessor = predecessor
            let newSuccessorIdentifiers = predecessor.successors.identifiers.union([version.identifier])
            newPredecessor.successors = Version.Successors(identifiers: newSuccessorIdentifiers)
            versionsByIdentifier[newPredecessor.identifier] = newPredecessor
        }
    }
    
    public func greatestCommonAncestor(ofVersionsIdentifiedBy identifiers: (Version.Identifier, Version.Identifier)) throws -> Version.Identifier? {
        // Find all ancestors of first Version. Determine how many generations back each Version is.
        // We take the shortest path to any given Version, ie, the minimum of possible paths.
        var generationById = [Version.Identifier:Int]()
        var firstFront: Set<Version.Identifier> = [identifiers.0]
        
        func propagateFront(front: inout Set<Version.Identifier>) throws {
            var newFront = Set<Version.Identifier>()
            for identifier in front {
                guard let frontVersion = self.version(identifiedBy: identifier) else {
                    throw Error.nonExistentVersionEncountered(identifier: identifier.identifierString)
                }
                newFront.formUnion(frontVersion.predecessors?.identifiers ?? [])
            }
            front = newFront
        }
        
        var generation = 0
        while firstFront.count > 0 {
            firstFront.forEach { generationById[$0] = Swift.min(generationById[$0] ?? Int.max, generation) }
            try propagateFront(front: &firstFront)
            generation += 1
        }
        
        // Now go through ancestors of second version until we find the first in common with the first ancestors
        var secondFront: Set<Version.Identifier> = [identifiers.1]
        let ancestorsOfFirst = Set(generationById.keys)
        while secondFront.count > 0 {
            let common = ancestorsOfFirst.intersection(secondFront)
            let sorted = common.sorted { generationById[$0]! < generationById[$1]! }
            if let mostRecentCommon = sorted.first { return mostRecentCommon }
            try propagateFront(front: &secondFront)
        }
        
        return nil
    }
}


extension History: Sequence {
    
    /// Enumerates history in a topological sorted order.
    /// Note that there are many possible orders that satisfy this.
    /// Most recent versions are ordered first (ie heads).
    /// Return false from block to stop.
    /// Uses Kahn algorithm to generate the order. https://en.wikipedia.org/wiki/Topological_sorting
    public struct TopologicalIterator: IteratorProtocol {
        public typealias Element = Version
        
        public let history: History
        
        private var front: Set<Version>
        private var referenceCountByIdentifier: [Version.Identifier:Int] = [:]
        
        init(toIterate history: History) {
            self.history = history
            let headVersions = history.headIdentifiers.map {
                history.version(identifiedBy: $0)!
            }
            self.front = Set(headVersions)
        }
        
        public mutating func next() -> Version? {
            guard let next = front.first(where: { version in
                    let refCount = self.referenceCountByIdentifier[version.identifier] ?? 0
                    let successorCount = version.successors.identifiers.count
                    return refCount == successorCount
                })
                else {
                    return nil
                }
            
            for predecessorIdentifier in next.predecessors?.identifiers ?? [] {
                let predecessor = history.version(identifiedBy: predecessorIdentifier)!
                referenceCountByIdentifier[predecessor.identifier] = (referenceCountByIdentifier[predecessor.identifier] ?? 0) + 1
                front.insert(predecessor)
            }
            
            front.remove(next)
            return next
        }
    }
    
    public func makeIterator() -> History.TopologicalIterator {
        return Iterator(toIterate: self)
    }
    
}
