//
//  Store.swift
//  llvs
//
//  Created by Drew McCormack on 31/10/2018.
//

import Foundation


// MARK:- Store

public final class Store {
    
    enum Error: Swift.Error {
        case missingVersion
        case attemptToLocateUnversionedValue
        case attemptToStoreValueWithNoVersion
        case noCommonAncestor(firstVersion: Version.Identifier, secondVersion: Version.Identifier)
        case unresolvedConflict(valueIdentifier: Value.Identifier, valueFork: Value.Fork)
        case attemptToAddExistingVersion(Version.Identifier)
        case attemptToAddVersionWithNonexistingPredecessors(Version)
    }
    
    public let rootDirectoryURL: URL
    public let valuesDirectoryURL: URL
    public let versionsDirectoryURL: URL
    public let mapsDirectoryURL: URL

    private let valuesZone: Zone
    
    private let valuesMapName = "__llvs_values"
    private let valuesMap: Map
    
    private let history = History()
    private let historyAccessQueue = DispatchQueue(label: "llvs.dispatchQueue.historyaccess")
    
    fileprivate let fileManager = FileManager()
    fileprivate let encoder = JSONEncoder()
    fileprivate let decoder = JSONDecoder()
    
    public init(rootDirectoryURL: URL) throws {
        self.rootDirectoryURL = rootDirectoryURL.resolvingSymlinksInPath()
        self.valuesDirectoryURL = rootDirectoryURL.appendingPathComponent("values")
        self.versionsDirectoryURL = rootDirectoryURL.appendingPathComponent("versions")
        self.mapsDirectoryURL = rootDirectoryURL.appendingPathComponent("maps")
        try? fileManager.createDirectory(at: self.rootDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        try? fileManager.createDirectory(at: self.valuesDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        try? fileManager.createDirectory(at: self.versionsDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        try? fileManager.createDirectory(at: self.mapsDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        
        let valuesMapZone = FileZone(rootDirectory: self.mapsDirectoryURL.appendingPathComponent(valuesMapName), fileExtension: "json")
        valuesMap = Map(zone: valuesMapZone)
        valuesZone = FileZone(rootDirectory: self.valuesDirectoryURL, fileExtension: "json")

        try reloadHistory()
    }
    
    public func reloadHistory() throws {
        try historyAccessQueue.sync {
            var newVersions: Set<Version> = []
            for version in try versions() where history.version(identifiedBy: version.identifier) == nil {
                newVersions.insert(version)
                try history.add(version, updatingPredecessorVersions: false)
            }
            for version in newVersions {
                try history.updateSuccessors(inPredecessorsOf: version)
            }
        }
    }
    
    public func queryHistory(in block: (History)->Void) {
        historyAccessQueue.sync {
            block(self.history)
        }
    }
    
    public func history(includesVersionsIdentifiedBy versionIdentifiers: [Version.Identifier]) -> Bool {
        var valid = false
        queryHistory { history in
            valid = versionIdentifiers.allSatisfy { history.version(identifiedBy: $0) != nil }
        }
        return valid
    }
    
}


// MARK:- Storing Values and Versions

extension Store {
    
    @discardableResult public func addVersion(basedOnPredecessor version: Version.Identifier?, storing changes: [Value.Change]) throws -> Version {
        let predecessors = version.flatMap { Version.Predecessors(identifierOfFirst: $0, identifierOfSecond: nil) }
        return try addVersion(basedOn: predecessors, storing: changes)
    }
    
    /// Changes must include all updates to the map of the first predecessor. If necessary, preserves should be included to bring values
    /// from the second predecessor into the first predecessor map.
    @discardableResult internal func addVersion(basedOn predecessors: Version.Predecessors?, storing changes: [Value.Change]) throws -> Version {
        let version = Version(predecessors: predecessors)
        try addVersion(version, storing: changes)
        return version
    }
    
    /// This method does not check consistency, and does not automatically update the map.
    /// It is assumed that any changes to the first predecessor that are needed in the map
    /// are present as preserves from the second predecessor.
    internal func addVersion(_ version: Version, storing changes: [Value.Change]) throws {
        guard !history(includesVersionsIdentifiedBy: [version.identifier]) else {
            throw Error.attemptToAddExistingVersion(version.identifier)
        }
        guard history(includesVersionsIdentifiedBy: version.predecessors?.identifiers ?? []) else {
            throw Error.attemptToAddVersionWithNonexistingPredecessors(version)
        }
        
        // Store values
        for change in changes {
            switch change {
            case .insert(let value), .update(let value):
                var newValue = value
                newValue.version = version.identifier
                try self.store(newValue)
            case .remove, .preserve, .preserveRemoval:
                continue
            }
        }
        
        // Update values map
        let deltas: [Map.Delta] = changes.map { change in
            switch change {
            case .insert(let value), .update(let value):
                let valueRef = Value.Reference(identifier: value.identifier, version: version.identifier)
                var delta = Map.Delta(key: Map.Key(value.identifier.identifierString))
                delta.addedValueReferences = [valueRef]
                return delta
            case .remove(let valueId), .preserveRemoval(let valueId):
                var delta = Map.Delta(key: Map.Key(valueId.identifierString))
                delta.removedValueIdentifiers = [valueId]
                return delta
            case .preserve(let valueRef):
                var delta = Map.Delta(key: Map.Key(valueRef.identifier.identifierString))
                delta.addedValueReferences = [valueRef]
                return delta
            }
        }
        try valuesMap.addVersion(version.identifier, basedOn: version.predecessors?.identifierOfFirst, applying: deltas)
        
        // Store version
        try store(version)
        
        // Add to history
        try historyAccessQueue.sync {
            try history.add(version, updatingPredecessorVersions: true)
        }
    }
    
    private func store(_ value: Value) throws {
        guard let zoneRef = value.zoneReference else { throw Error.attemptToStoreValueWithNoVersion }
        try valuesZone.store(value.data, for: zoneRef)
    }
}


// MARK:- Merging

extension Store {
    
    /// Will choose between a three way merge, and a two way merge, based on whether a common ancestor is found.
    public func merge(version firstVersionIdentifier: Version.Identifier, with secondVersionIdentifier: Version.Identifier, resolvingWith arbiter: MergeArbiter) throws -> Version {
        do {
            return try mergeRelated(version: firstVersionIdentifier, with: secondVersionIdentifier, resolvingWith: arbiter)
        } catch Error.noCommonAncestor {
            return try mergeUnrelated(version: firstVersionIdentifier, with: secondVersionIdentifier, resolvingWith: arbiter)
        }
    }
    
    /// Two-way merge between two versions that have no common ancestry. Effectively we assume an empty common ancestor,
    /// so that all changes are inserts, or conflicting twiceInserts.
    public func mergeUnrelated(version firstVersionIdentifier: Version.Identifier, with secondVersionIdentifier: Version.Identifier, resolvingWith arbiter: MergeArbiter) throws -> Version {
        var firstVersion, secondVersion: Version?
        var fastForwardVersion: Version?
        try historyAccessQueue.sync {
            firstVersion = history.version(identifiedBy: firstVersionIdentifier)
            secondVersion = history.version(identifiedBy: secondVersionIdentifier)

            guard firstVersion != nil, secondVersion != nil else {
                throw Error.missingVersion
            }
            
            // Check for fast forward
            if history.isAncestralLine(from: firstVersion!.identifier, to: secondVersion!.identifier) {
                fastForwardVersion = secondVersion
            } else if history.isAncestralLine(from: secondVersion!.identifier, to: firstVersion!.identifier) {
                fastForwardVersion = firstVersion
            }
        }
        
        if let fastForwardVersion = fastForwardVersion {
            return fastForwardVersion
        }

        return try merge(firstVersion!, and: secondVersion!, withCommonAncestor: nil, resolvingWith: arbiter)
    }
    
    /// Three-way merge between two versions, and a common ancestor. If no common ancestor is found, a .noCommonAncestor error is thrown.
    /// Conflicts are resolved using the MergeArbiter passed in.
    public func mergeRelated(version firstVersionIdentifier: Version.Identifier, with secondVersionIdentifier: Version.Identifier, resolvingWith arbiter: MergeArbiter) throws -> Version {
        var firstVersion, secondVersion, commonVersion: Version?
        var commonVersionIdentifier: Version.Identifier?
        try historyAccessQueue.sync {
            commonVersionIdentifier = try history.greatestCommonAncestor(ofVersionsIdentifiedBy: (firstVersionIdentifier, secondVersionIdentifier))
            guard commonVersionIdentifier != nil else {
                throw Error.noCommonAncestor(firstVersion: firstVersionIdentifier, secondVersion: secondVersionIdentifier)
            }
            
            firstVersion = history.version(identifiedBy: firstVersionIdentifier)
            secondVersion = history.version(identifiedBy: secondVersionIdentifier)
            commonVersion = history.version(identifiedBy: commonVersionIdentifier!)
            
            guard firstVersion != nil, secondVersion != nil else {
                throw Error.missingVersion
            }
        }
        
        // Check for fast forward cases where no merge is needed
        if firstVersionIdentifier == commonVersionIdentifier {
            return secondVersion!
        } else if secondVersionIdentifier == commonVersionIdentifier {
            return firstVersion!
        }
        
        return try merge(firstVersion!, and: secondVersion!, withCommonAncestor: commonVersion!, resolvingWith: arbiter)
    }
    
    /// Two or three-way merge. Does no check to see if fast forwarding is possible. Will carry out the merge regardless of history.
    /// If a common ancestor is supplied, it is 3-way, and otherwise 2-way.
    private func merge(_ firstVersion: Version, and secondVersion: Version, withCommonAncestor commonAncestor: Version?, resolvingWith arbiter: MergeArbiter) throws -> Version {
        // Prepare merge
        let predecessors = Version.Predecessors(identifierOfFirst: firstVersion.identifier, identifierOfSecond: secondVersion.identifier)
        let diffs = try valuesMap.differences(between: firstVersion.identifier, and: secondVersion.identifier, withCommonAncestor: commonAncestor?.identifier)
        var merge = Merge(versions: (firstVersion, secondVersion), commonAncestor: commonAncestor)
        let forkTuples = diffs.map({ ($0.valueIdentifier, $0.valueFork) })
        merge.forksByValueIdentifier = .init(uniqueKeysWithValues: forkTuples)
        
        // Resolve with arbiter
        var changes = try arbiter.changes(toResolve: merge, in: self)
        
        // Check changes resolve conflicts
        let idsInChanges = Set(changes.valueIdentifiers)
        for diff in diffs {
            if diff.valueFork.isConflicting && !idsInChanges.contains(diff.valueIdentifier) {
                throw Error.unresolvedConflict(valueIdentifier: diff.valueIdentifier, valueFork: diff.valueFork)
            }
        }
        
        // Must make sure any change that was made in the second predecessor is included,
        // via a 'preserve' if necessary.
        // This is so the map of the first predecessor is updated properly.
        for diff in diffs where !idsInChanges.contains(diff.valueIdentifier) {
            switch diff.valueFork {
            case .inserted(let branch) where branch == .second:
                fallthrough
            case .updated(let branch) where branch == .second:
                let ref = try valueReference(diff.valueIdentifier, prevailingAt: secondVersion.identifier)!
                changes.append(.preserve(ref))
            case .removed(let branch) where branch == .second:
                changes.append(.preserveRemoval(diff.valueIdentifier))
            default:
                break
            }
        }
        
        return try addVersion(basedOn: predecessors, storing: changes)
    }
    
}


// MARK:- Fetching Values

extension Store {
    
    public func valueReference(_ valueIdentifier: Value.Identifier, prevailingAt versionIdentifier: Version.Identifier) throws -> Value.Reference? {
        return try valuesMap.valueReferences(matching: .init(valueIdentifier.identifierString), at: versionIdentifier).first
    }
    
    public func value(_ valueIdentifier: Value.Identifier, prevailingAt versionIdentifier: Version.Identifier) throws -> Value? {
        let ref = try valueReference(valueIdentifier, prevailingAt: versionIdentifier)
        return try ref.flatMap { try value(valueIdentifier, storedAt: $0.version) }
    }
    
    internal func value(_ valueIdentifier: Value.Identifier, storedAt versionIdentifier: Version.Identifier) throws -> Value? {
        guard let data = try valuesZone.data(for: .init(key: valueIdentifier.identifierString, version: versionIdentifier)) else { return nil }
        let value = Value(identifier: valueIdentifier, version: versionIdentifier, data: data)
        return value
    }
    
}


// MARK:- Value Changes

extension Store {
    
    public func valueChanges(madeInVersionIdentifiedBy versionId: Version.Identifier) throws -> [Value.Change] {
        guard let version = try version(identifiedBy: versionId) else { throw Error.missingVersion }
        
        guard let predecessors = version.predecessors else {
            var changes: [Value.Change] = []
            try valuesMap.enumerateValueReferences(forVersionIdentifiedBy: versionId) { ref in
                let v = try value(ref.identifier, storedAt: ref.version)!
                changes.append(.insert(v))
            }
            return changes
        }
        
        var changes: [Value.Change] = []
        let p1 = predecessors.identifierOfFirst
        if let p2 = predecessors.identifierOfSecond {
            // Do a reverse-in-time fork, and negate the outcome
            let diffs = try valuesMap.differences(between: p1, and: p2, withCommonAncestor: versionId)
            for diff in diffs {
                switch diff.valueFork {
                case .twiceInserted:
                    changes.append(.remove(diff.valueIdentifier))
                case .twiceUpdated, .removedAndUpdated:
                    let value = try self.value(diff.valueIdentifier, prevailingAt: versionId)!
                    changes.append(.update(value))
                case .twiceRemoved:
                    let value = try self.value(diff.valueIdentifier, prevailingAt: versionId)!
                    changes.append(.insert(value))
                case .inserted:
                    changes.append(.preserveRemoval(diff.valueIdentifier))
                case .removed, .updated:
                    let value = try self.value(diff.valueIdentifier, prevailingAt: versionId)!
                    changes.append(.preserve(value.reference!))
                }
            }
        } else {
            let diffs = try valuesMap.differences(between: versionId, and: p1, withCommonAncestor: p1)
            for diff in diffs {
                switch diff.valueFork {
                case .inserted:
                    let value = try self.value(diff.valueIdentifier, prevailingAt: versionId)!
                    changes.append(.insert(value))
                case .removed:
                    changes.append(.remove(diff.valueIdentifier))
                case .updated:
                    let value = try self.value(diff.valueIdentifier, prevailingAt: versionId)!
                    changes.append(.update(value))
                case .removedAndUpdated, .twiceInserted, .twiceRemoved, .twiceUpdated:
                    fatalError("Should not be possible with only a single branch")
                }
            }
        }
        
        return changes
    }
    
}


// MARK:- Storing and Fetching Versions

extension Store {
    
    fileprivate func store(_ version: Version) throws {
        let (dir, file) = fileSystemLocation(forVersionIdentifiedBy: version.identifier)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        let data = try encoder.encode(version)
        try data.write(to: file)
    }
    
    internal func versionIdentifiers(for valueIdentifier: Value.Identifier) throws -> [Version.Identifier] {
        let valueDirectoryURL = valuesDirectoryURL.appendingSplitPathComponent(valueIdentifier.identifierString)
        let enumerator = fileManager.enumerator(at: valueDirectoryURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])!
        let valueDirComponents = valueDirectoryURL.standardizedFileURL.pathComponents
        var versionIdentifiers: [Version.Identifier] = []
        for any in enumerator {
            var isDirectory: ObjCBool = true
            guard let url = any as? URL else { continue }
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue else { continue }
            guard url.pathExtension == "json" else { continue }
            let allComponents = url.standardizedFileURL.deletingPathExtension().pathComponents
            let versionComponents = allComponents[valueDirComponents.count...]
            let versionString = versionComponents.joined()
            versionIdentifiers.append(.init(versionString))
        }
        return versionIdentifiers
    }
    
    fileprivate func versions() throws -> [Version] {
        let enumerator = fileManager.enumerator(at: versionsDirectoryURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])!
        var versions: [Version] = []
        for any in enumerator {
            var isDirectory: ObjCBool = true
            guard let url = any as? URL else { continue }
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue else { continue }
            guard url.pathExtension == "json" else { continue }
            let data = try Data(contentsOf: url)
            let version = try decoder.decode(Version.self, from: data)
            versions.append(version)
        }
        return versions
    }
    
    public func version(identifiedBy versionId: Version.Identifier) throws -> Version? {
        var version: Version?
        queryHistory { history in
            version = history.version(identifiedBy: versionId)
        }
        return version
    }
    
    public var mostRecentHead: Version? {
        var version: Version?
        queryHistory { history in
            version = history.mostRecentHead
        }
        return version
    }

}


// MARK:- File System Locations

fileprivate extension Store {
    
    func fileSystemLocation(forVersionIdentifiedBy identifier: Version.Identifier) -> (directoryURL: URL, fileURL: URL) {
        let fileURL = versionsDirectoryURL.appendingSplitPathComponent(identifier.identifierString).appendingPathExtension("json")
        let directoryURL = fileURL.deletingLastPathComponent()
        return (directoryURL: directoryURL, fileURL: fileURL)
    }
}


// MARK:- Path Utilities

internal extension URL {
    
    /// Appends a path to the messaged URL that consists of a filename for which
    /// a prefix is taken as a subdirectory. Eg. `file:///root` might become
    /// `file:///root/fi/lename.jpg` when appending `filename.jpg` with `subDirectoryNameLength` of 2.
    func appendingSplitPathComponent(_ name: String, prefixLength: UInt = 2) -> URL {
        guard name.count > prefixLength else {
            return appendingPathComponent(name)
        }
        
        // Embed a subdirectory
        let index = name.index(name.startIndex, offsetBy: Int(prefixLength))
        let prefix = String(name[..<index])
        let postfix = String(name[index...])
        let directory = appendingPathComponent(prefix).appendingPathComponent(postfix)
        
        return directory
    }
    
}
