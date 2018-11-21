//
//  History.swift
//  LLVS
//
//  Created by Drew McCormack on 11/11/2018.
//

import Foundation

public final class History {
    
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
    
    public func version(prevailingFromCandidates candidates: [Version.Identifier], atVersionIdentifiedBy versionIdentifier: Version.Identifier) -> Version? {
        let candidateSet = Set<Version.Identifier>(candidates)
        var predecessors: [Version] = [versionIdentifier].compactMap { self.version(identifiedBy: $0) }
        while !predecessors.isEmpty, candidateSet.isDisjoint(with: predecessors.map({ $0.identifier })) {
            predecessors = predecessors.flatMap { (predecessor) -> [Version] in
                let new = predecessor.predecessors?.identifiers ?? []
                return new.compactMap { self.version(identifiedBy: $0) }
            }
        }
        return predecessors.first { candidateSet.contains($0.identifier) }
    }
    
    internal func add(_ version: Version) throws {
        guard versionsByIdentifier[version.identifier] == nil else {
            throw Error.attemptToAddPreexistingVersion(identifier: version.identifier.identifierString)
        }
        versionsByIdentifier[version.identifier] = version
        for predecessor in version.predecessors?.identifiers ?? [] {
            referencedVersionIdentifiers.insert(predecessor)
            headIdentifiers.remove(predecessor)
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

}
