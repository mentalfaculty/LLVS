//
//  History.swift
//  LLVS
//
//  Created by Drew McCormack on 11/11/2018.
//

import Foundation

public struct History {
    
    public enum Error: Swift.Error {
        case attemptToAddPreexistingVersion(identifier: String)
        case nonExistentVersionEncountered(identifier: String)
    }
    
    private var versionsByIdentifier: [Version.Identifier:Version] = [:]
    private var referencedVersionIdentifiers: Set<Version.Identifier> = [] // Any version that is a predecessor
    public private(set) var headIdentifiers: Set<Version.Identifier> = [] // Versions that are not predecessors of other versions
    
    public var mostRecentHead: Version? {
        return headIdentifiers.map({ version(identifiedBy: $0)! }).sorted(by: { $0.timestamp < $1.timestamp }).last
    }
    
    public func version(identifiedBy identifier: Version.Identifier) -> Version? {
        return versionsByIdentifier[identifier]
    }
    
    internal func version(prevailingFromCandidates candidates: [Version.Identifier], at versionIdentifier: Version.Identifier) -> Version? {
        let sortedIdentifiers = sortedVersionIdentifiers()
        let index = sortedIdentifiers.first { candidates.contains($0) }
        
//        guard let root = version(identifiedBy: versionIdentifier) else { return nil }
//
//        // Use Kahn algorithm to search back for the first candidate in our list. https://en.wikipedia.org/wiki/Topological_sorting
//        let candidateSet = Set<Version.Identifier>(candidates)
//        var predecessors: Set<Version> = Set([versionIdentifier].compactMap({ self.version(identifiedBy: $0) }))
//        var countByIdentifier: [Version.Identifier:Int] = [versionIdentifier:root.successors.identifiers.count]
//        while !predecessors.isEmpty, candidateSet.isDisjoint(with: predecessors.identifiers) {
//            // Note that a version can appear more than once in newPredecessors
//            var newPredecessors = predecessors.flatMap { (predecessor) -> [Version] in
//                let new = predecessor.predecessors?.identifiers ?? []
//                return new.compactMap { self.version(identifiedBy: $0) }
//            }
//
//            // Increase visit count
//            newPredecessors.forEach {
//                countByIdentifier[$0.identifier] = (countByIdentifier[$0.identifier] ?? 0) + 1
//            }
//
//            // Remove any new predecessors that have not been visited via all references
//            newPredecessors = newPredecessors.filter({ countByIdentifier[$0.identifier] == $0.successors.identifiers.count })
//
//            // Update set of predecessors (removes duplicates)
//            predecessors = Set(newPredecessors)
//        }
//        return predecessors.first { candidateSet.contains($0.identifier) }
    }
    
    /// If updatingPredecessorVersions is true, the successors of other versions may be updated.
    /// Use this when adding a new head when storing.
    /// Pass in false if the versions alreeady have their successors up-to-date, for example,
    /// when loading them to setup the History.
    internal mutating func add(_ version: Version, updatingPredecessorVersions: Bool) throws {
        guard versionsByIdentifier[version.identifier] == nil else {
            throw Error.attemptToAddPreexistingVersion(identifier: version.identifier.identifierString)
        }
        versionsByIdentifier[version.identifier] = version
        for predecessorIdentifier in version.predecessors?.identifiers ?? [] {
            referencedVersionIdentifiers.insert(predecessorIdentifier)
            headIdentifiers.remove(predecessorIdentifier)
            if updatingPredecessorVersions, let predecessor = self.version(identifiedBy: predecessorIdentifier) {
                var newPredecessor = predecessor
                let newSuccessorIdentifiers = predecessor.successors.identifiers.union([version.identifier])
                newPredecessor.successors = Version.Successors(identifiers: newSuccessorIdentifiers)
                versionsByIdentifier[newPredecessor.identifier] = newPredecessor
            }
        }
        if !referencedVersionIdentifiers.contains(version.identifier) {
            headIdentifiers.insert(version.identifier)
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
            firstFront.forEach { generationById[$0] = min(generationById[$0] ?? Int.max, generation) }
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
    
    /// Enumerates whole history in a topological sorted order. Note that there are many possible orders that satisfy this.
    /// Most recent versions are ordered first (ie heads).
    /// Return false from block to stop.
    /// Uses Kahn algorithm to generate the order. https://en.wikipedia.org/wiki/Topological_sorting
    func enumerate(executingForEachVersion block:(Version)->Bool) {
        var predecessors: Set<Version> = Set(headIdentifiers.map { version(identifiedBy: $0)! })
        
        // Visit head versions
        for p in predecessors {
            if !block(p) { return }
        }
    
        // Move through whole tree, stepping back to the previous version one at a time.
        var referenceCountByIdentfier: [Version.Identifier:Int] = [:]
        while !predecessors.isEmpty {
            // Note that a version can appear more than once in newPredecessors
            var newPredecessors = predecessors.flatMap { (predecessor) -> [Version] in
                let new = predecessor.predecessors?.identifiers ?? []
                return new.compactMap { self.version(identifiedBy: $0) }
            }
            
            // Increase reference count for each
            newPredecessors.forEach {
                referenceCountByIdentfier[$0.identifier] = (referenceCountByIdentfier[$0.identifier] ?? 0) + 1
            }
            
            // Remove any new predecessors that have not been visited via all references to them
            newPredecessors = newPredecessors.filter {
                referenceCountByIdentfier[$0.identifier] == $0.successors.identifiers.count
            }
            
            // Visit new versions
            for p in newPredecessors {
                if !block(p) { return }
            }
            
            // Update set of predecessors (removes duplicates)
            predecessors = Set(newPredecessors)
        }
    }

    
    /// Returns a topological sort order of the history. Note that there are many possible orders that satisfy this.
    /// Most recent versions are ordered first (ie heads).
    /// Uses Kahn algorithm to generate the order. https://en.wikipedia.org/wiki/Topological_sorting
    func sortedVersionIdentifiers() -> [Version.Identifier] {
        var result: [Version.Identifier] = Array(headIdentifiers)
        enumerate { version in
            result.append(version.identifier)
            return true
        }
        return result
    }
}
