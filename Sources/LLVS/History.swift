//
//  History.swift
//  LLVS
//
//  Created by Drew McCormack on 11/11/2018.
//

import Foundation

public final class History {
    
    private var versionsByIdentifier: [Version.Identifier:Version] = [:]
    private var referencedVersionIdentifiers: Set<Version.Identifier> = [] // Any version that is a predecessor
    public var headIdentifiers: Set<Version.Identifier> = [] // Versions that are not predecessors of other versions
    
    public var mostRecentHead: Version? {
        return headIdentifiers.map({ version(identifiedBy: $0)! }).sorted(by: { $0.timestamp < $1.timestamp }).last
    }
    
    public func version(identifiedBy identifier: Version.Identifier) -> Version? {
        return versionsByIdentifier[identifier]
    }
    
    internal func add(_ version: Version) {
        precondition(versionsByIdentifier[version.identifier] == nil)
        versionsByIdentifier[version.identifier] = version
        for predecessor in version.predecessors?.identifiers ?? [] {
            referencedVersionIdentifiers.insert(predecessor)
            headIdentifiers.remove(predecessor)
        }
        if !referencedVersionIdentifiers.contains(version.identifier) {
            headIdentifiers.insert(version.identifier)
        }
    }
    
    public func greatestCommonAncestor(ofVersionsIdentifiedBy identifiers: (Version.Identifier, Version.Identifier)) -> Version.Identifier? {
        // Find all ancestors of first Version. Determine how many generations back each Version is.
        // We take the shortest path to any given Version, ie, the minimum of possible paths.
        var generationById = [Version.Identifier:Int]()
        var firstFront: Set<Version.Identifier> = [identifiers.0]
        
        func propagateFront() {
            var newFront = Set<Version.Identifier>()
            for identifier in firstFront {
                let frontVersion = self.version(identifiedBy: identifier)!
                newFront.formUnion(frontVersion.predecessors?.identifiers ?? [])
            }
            firstFront = newFront
        }
        
        var generation = 0
        while firstFront.count > 0 {
            firstFront.forEach { generationById[$0] = min(generationById[$0] ?? Int.max, generation) }
            propagateFront()
            generation += 1
        }
        
        // Now go through ancestors of second version until we find the first in common with the first ancestors
        let secondFront = [identifiers.1]
        let ancestorsOfFirst = Set(generationById.keys)
        while secondFront.count > 0 {
            let common = ancestorsOfFirst.intersection(secondFront)
            let sorted = common.sorted { generationById[$0]! < generationById[$1]! }
            if let mostRecentCommon = sorted.first { return mostRecentCommon }
            propagateFront()
        }
        
        return nil
    }

}
