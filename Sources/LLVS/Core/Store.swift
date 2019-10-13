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
        case noCommonAncestor(firstVersion: Version.ID, secondVersion: Version.ID)
        case unresolvedConflict(valueId: Value.ID, valueFork: Value.Fork)
        case attemptToAddExistingVersion(Version.ID)
        case attemptToAddVersionWithNonexistingPredecessors(Version)
    }
    
    public let rootDirectoryURL: URL
    public let valuesDirectoryURL: URL
    public let versionsDirectoryURL: URL
    public let mapsDirectoryURL: URL
    public let valuesMapDirectoryURL: URL
    
    public let storage: Storage

    private lazy var valuesZone: Zone = {
        return storage.makeValuesZone(in: self)
    }()
    
    private let valuesMapName = "__llvs_values"
    private lazy var valuesMap: Map = {
        let valuesMapZone = self.storage.makeMapZone(for: .valuesByVersion, in: self)
        return Map(zone: valuesMapZone)
    }()
    
    private let history = History()
    private let historyAccessQueue = DispatchQueue(label: "llvs.dispatchQueue.historyaccess")
    
    fileprivate let fileManager = FileManager()
    fileprivate let encoder = JSONEncoder()
    fileprivate let decoder = JSONDecoder()
    
    public init(rootDirectoryURL: URL, storage: Storage = FileStorage()) throws {
        self.storage = storage
        
        self.rootDirectoryURL = rootDirectoryURL.resolvingSymlinksInPath()
        self.valuesDirectoryURL = rootDirectoryURL.appendingPathComponent("values")
        self.versionsDirectoryURL = rootDirectoryURL.appendingPathComponent("versions")
        self.mapsDirectoryURL = rootDirectoryURL.appendingPathComponent("maps")
        self.valuesMapDirectoryURL = self.mapsDirectoryURL.appendingPathComponent(valuesMapName)

        try? fileManager.createDirectory(at: self.rootDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        try? fileManager.createDirectory(at: self.valuesDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        try? fileManager.createDirectory(at: self.versionsDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        try? fileManager.createDirectory(at: self.mapsDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        
        try reloadHistory()
    }
    
    /// Call this to make sure all history is loaded. For example, if the store could have been
    /// changed by another process, calling this method will ensure the versions added by that process
    /// are loaded.
    public func reloadHistory() throws {
        try historyAccessQueue.sync {
            var newVersions: Set<Version> = []
            for version in try storedVersions() where history.version(identifiedBy: version.id) == nil {
                newVersions.insert(version)
                try history.add(version, updatingPredecessorVersions: false)
            }
            for version in newVersions {
                try history.updateSuccessors(inPredecessorsOf: version)
            }
        }
    }
    
    /// Provides access to the history object in a serialized way, allowing access from any thread.
    /// Calls the block passed after getting exclusive history to the history object, and passes the history.
    public func queryHistory(in block: (History) throws ->Void) rethrows {
        try historyAccessQueue.sync {
            try block(self.history)
        }
    }
    
    public func historyIncludesVersions(identifiedBy versionIds: [Version.ID]) -> Bool {
        var valid = false
        queryHistory { history in
            valid = versionIds.allSatisfy { history.version(identifiedBy: $0) != nil }
        }
        return valid
    }
    
}


// MARK:- Storing Values and Versions

extension Store {
    
    /// Convenience to avoid having to create Value.Change values yourself
    @discardableResult public func makeVersion(basedOnPredecessor versionId: Version.ID?, inserting insertedValues: [Value] = [], updating updatedValues: [Value] = [], removing removedIds: [Value.ID] = [], metadata: Data? = nil) throws -> Version {
        let predecessors = versionId.flatMap { Version.Predecessors(idOfFirst: $0, idOfSecond: nil) }
        let inserts: [Value.Change] = insertedValues.map { .insert($0) }
        let updates: [Value.Change] = updatedValues.map { .update($0) }
        let removes: [Value.Change] = removedIds.map { .remove($0) }
        return try makeVersion(basedOn: predecessors, storing: inserts+updates+removes, metadata: metadata)
    }
    
    @discardableResult public func makeVersion(basedOnPredecessor version: Version.ID?, storing changes: [Value.Change], metadata: Data? = nil) throws -> Version {
        let predecessors = version.flatMap { Version.Predecessors(idOfFirst: $0, idOfSecond: nil) }
        return try makeVersion(basedOn: predecessors, storing: changes, metadata: metadata)
    }
    
    /// Changes must include all updates to the map of the first predecessor. If necessary, preserves should be included to bring values
    /// from the second predecessor into the first predecessor map.
    @discardableResult internal func makeVersion(basedOn predecessors: Version.Predecessors?, storing changes: [Value.Change], metadata: Data? = nil) throws -> Version {
        let version = Version(predecessors: predecessors, metadata: metadata)
        try addVersion(version, storing: changes)
        return version
    }
    
    /// This method does not check consistency, and does not automatically update the map.
    /// It is assumed that any changes to the first predecessor that are needed in the map
    /// are present as preserves from the second predecessor.
    internal func addVersion(_ version: Version, storing changes: [Value.Change]) throws {
        guard !historyIncludesVersions(identifiedBy: [version.id]) else {
            throw Error.attemptToAddExistingVersion(version.id)
        }
        guard historyIncludesVersions(identifiedBy: version.predecessors?.ids ?? []) else {
            throw Error.attemptToAddVersionWithNonexistingPredecessors(version)
        }
        
        // Store values
        for change in changes {
            switch change {
            case .insert(let value), .update(let value):
                var newValue = value
                newValue.storedVersionId = version.id
                try self.store(newValue)
            case .remove, .preserve, .preserveRemoval:
                continue
            }
        }
        
        // Update values map
        let deltas: [Map.Delta] = changes.map { change in
            switch change {
            case .insert(let value), .update(let value):
                let valueRef = Value.Reference(valueId: value.id, storedVersionId: version.id)
                var delta = Map.Delta(key: Map.Key(value.id.stringValue))
                delta.addedValueReferences = [valueRef]
                return delta
            case .remove(let valueId), .preserveRemoval(let valueId):
                var delta = Map.Delta(key: Map.Key(valueId.stringValue))
                delta.removedValueIdentifiers = [valueId]
                return delta
            case .preserve(let valueRef):
                var delta = Map.Delta(key: Map.Key(valueRef.valueId.stringValue))
                delta.addedValueReferences = [valueRef]
                return delta
            }
        }
        try valuesMap.addVersion(version.id, basedOn: version.predecessors?.idOfFirst, applying: deltas)
        
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


// MARK:- Fetching Values

extension Store {
    
    public func valueReference(id valueId: Value.ID, at versionId: Version.ID) throws -> Value.Reference? {
        return try valuesMap.valueReferences(matching: .init(valueId.stringValue), at: versionId).first
    }
    
    /// Convenient method to avoid having to create id types
    public func value(idString valueIdString: String, at versionId: Version.ID) throws -> Value? {
        return try value(id: .init(valueIdString), at: versionId)
    }
    
    public func value(id valueId: Value.ID, at versionId: Version.ID) throws -> Value? {
        let ref = try valueReference(id: valueId, at: versionId)
        return try ref.flatMap { try value(id: valueId, storedAt: $0.storedVersionId) }
    }
    
    public func value(id valueId: Value.ID, storedAt versionId: Version.ID) throws -> Value? {
        guard let data = try valuesZone.data(for: .init(key: valueId.stringValue, version: versionId)) else { return nil }
        let value = Value(id: valueId, storedVersionId: versionId, data: data)
        return value
    }
    
    public func value(storedAt valueReference: Value.Reference) throws -> Value? {
        return try value(id: valueReference.valueId, storedAt: valueReference.storedVersionId)
    }
    
    public func enumerate(version versionId: Version.ID, executingForEach block: (Value.Reference) throws -> Void) throws {
        try valuesMap.enumerateValueReferences(forVersionIdentifiedBy: versionId, executingForEach: block)
    }
    
}


// MARK:- Merging

extension Store {
    
    /// Whether there is more than one head
    public var hasMultipleHeads: Bool {
        var result: Bool = false
        queryHistory { history in
            result = history.headIdentifiers.count > 1
        }
        return result
    }
    
    /// Merges heads into the version passed, which is usually a head itself. This is a convenience
    /// to save looping through all heads.
    /// If the version ends up being changed by the merging, the new version is returned, otherwise nil.
    public func mergeHeads(into version: Version.ID, resolvingWith arbiter: MergeArbiter) -> Version.ID? {
        var heads: Set<Version.ID> = []
        queryHistory { history in
            heads = history.headIdentifiers
        }
        heads.remove(version)
        
        guard !heads.isEmpty else { return nil }
        
        var versionId: Version.ID = version
        for otherHead in heads {
            let newVersion = try! merge(version: versionId, with: otherHead, resolvingWith: arbiter)
            versionId = newVersion.id
        }
        
        return versionId
    }
    
    /// Will choose between a three way merge, and a two way merge, based on whether a common ancestor is found.
    public func merge(version firstVersionIdentifier: Version.ID, with secondVersionIdentifier: Version.ID, resolvingWith arbiter: MergeArbiter, metadata: Data? = nil) throws -> Version {
        do {
            return try mergeRelated(version: firstVersionIdentifier, with: secondVersionIdentifier, resolvingWith: arbiter, metadata: metadata)
        } catch Error.noCommonAncestor {
            return try mergeUnrelated(version: firstVersionIdentifier, with: secondVersionIdentifier, resolvingWith: arbiter, metadata: metadata)
        }
    }
    
    /// Two-way merge between two versions that have no common ancestry. Effectively we assume an empty common ancestor,
    /// so that all changes are inserts, or conflicting twiceInserts.
    public func mergeUnrelated(version firstVersionIdentifier: Version.ID, with secondVersionIdentifier: Version.ID, resolvingWith arbiter: MergeArbiter, metadata: Data? = nil) throws -> Version {
        var firstVersion, secondVersion: Version?
        var fastForwardVersion: Version?
        try historyAccessQueue.sync {
            firstVersion = history.version(identifiedBy: firstVersionIdentifier)
            secondVersion = history.version(identifiedBy: secondVersionIdentifier)

            guard firstVersion != nil, secondVersion != nil else {
                throw Error.missingVersion
            }
            
            // Check for fast forward
            if history.isAncestralLine(from: firstVersion!.id, to: secondVersion!.id) {
                fastForwardVersion = secondVersion
            } else if history.isAncestralLine(from: secondVersion!.id, to: firstVersion!.id) {
                fastForwardVersion = firstVersion
            }
        }
        
        if let fastForwardVersion = fastForwardVersion {
            return fastForwardVersion
        }

        return try merge(firstVersion!, and: secondVersion!, withCommonAncestor: nil, resolvingWith: arbiter, metadata: metadata)
    }
    
    /// Three-way merge between two versions, and a common ancestor. If no common ancestor is found, a .noCommonAncestor error is thrown.
    /// Conflicts are resolved using the MergeArbiter passed in.
    public func mergeRelated(version firstVersionIdentifier: Version.ID, with secondVersionIdentifier: Version.ID, resolvingWith arbiter: MergeArbiter, metadata: Data? = nil) throws -> Version {
        var firstVersion, secondVersion, commonVersion: Version?
        var commonVersionIdentifier: Version.ID?
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
        
        return try merge(firstVersion!, and: secondVersion!, withCommonAncestor: commonVersion!, resolvingWith: arbiter, metadata: metadata)
    }
    
    /// Two or three-way merge. Does no check to see if fast forwarding is possible. Will carry out the merge regardless of history.
    /// If a common ancestor is supplied, it is 3-way, and otherwise 2-way.
    private func merge(_ firstVersion: Version, and secondVersion: Version, withCommonAncestor commonAncestor: Version?, resolvingWith arbiter: MergeArbiter, metadata: Data? = nil) throws -> Version {
        // Prepare merge
        let predecessors = Version.Predecessors(idOfFirst: firstVersion.id, idOfSecond: secondVersion.id)
        let diffs = try valuesMap.differences(between: firstVersion.id, and: secondVersion.id, withCommonAncestor: commonAncestor?.id)
        var merge = Merge(versions: (firstVersion, secondVersion), commonAncestor: commonAncestor)
        let forkTuples = diffs.map({ ($0.valueId, $0.valueFork) })
        merge.forksByValueIdentifier = .init(uniqueKeysWithValues: forkTuples)
        
        // Resolve with arbiter
        var changes = try arbiter.changes(toResolve: merge, in: self)
        
        // Check changes resolve conflicts
        let idsInChanges = Set(changes.valueIds)
        for diff in diffs {
            if diff.valueFork.isConflicting && !idsInChanges.contains(diff.valueId) {
                throw Error.unresolvedConflict(valueId: diff.valueId, valueFork: diff.valueFork)
            }
        }
        
        // Must make sure any change that was made in the second predecessor is included,
        // via a 'preserve' if necessary.
        // This is so the map of the first predecessor is updated properly.
        for diff in diffs where !idsInChanges.contains(diff.valueId) {
            switch diff.valueFork {
            case .inserted(let branch) where branch == .second:
                fallthrough
            case .updated(let branch) where branch == .second:
                let ref = try valueReference(id: diff.valueId, at: secondVersion.id)!
                changes.append(.preserve(ref))
            case .removed(let branch) where branch == .second:
                changes.append(.preserveRemoval(diff.valueId))
            default:
                break
            }
        }
        
        return try makeVersion(basedOn: predecessors, storing: changes, metadata: metadata)
    }
    
}


// MARK:- Value Changes

extension Store {
    
    /// Returns the changes actually made in the version passed. This is important for an exchange, for example, that wishes to
    /// store a set of changes. Note that it is not exactly equivalent to taking the diff between the  version and one of its predecessors,
    /// because in that case, any changes made in the branch of the other predecessor will also be included as changes, when they don't
    /// really belong (ie they were actually made in the past)
    public func valueChanges(madeInVersionIdentifiedBy versionId: Version.ID) throws -> [Value.Change] {
        guard let version = try version(identifiedBy: versionId) else { throw Error.missingVersion }
        
        guard let predecessors = version.predecessors else {
            var changes: [Value.Change] = []
            try valuesMap.enumerateValueReferences(forVersionIdentifiedBy: versionId) { ref in
                let v = try value(id: ref.valueId, storedAt: ref.storedVersionId)!
                changes.append(.insert(v))
            }
            return changes
        }
        
        var changes: [Value.Change] = []
        let p1 = predecessors.idOfFirst
        if let p2 = predecessors.idOfSecond {
            // Do a reverse-in-time fork, and negate the outcome
            let diffs = try valuesMap.differences(between: p1, and: p2, withCommonAncestor: versionId)
            for diff in diffs {
                switch diff.valueFork {
                case .twiceInserted:
                    changes.append(.remove(diff.valueId))
                case .twiceUpdated, .removedAndUpdated:
                    let value = try self.value(id: diff.valueId, at: versionId)!
                    changes.append(.update(value))
                case .twiceRemoved:
                    let value = try self.value(id: diff.valueId, at: versionId)!
                    changes.append(.insert(value))
                case .inserted:
                    changes.append(.preserveRemoval(diff.valueId))
                case .removed, .updated:
                    let value = try self.value(id: diff.valueId, at: versionId)!
                    changes.append(.preserve(value.reference!))
                }
            }
        } else {
            changes = try valueChanges(madeBetween: p1, and: version.id)
        }
        
        return changes
    }
    
    /// Changes that can be applied to go from the first version to the second. Useful for "diffing", eg, updating UI by seeing what changed.
    public func valueChanges(madeBetween versionId1: Version.ID, and versionId2: Version.ID) throws -> [Value.Change] {
        guard let _ = try version(identifiedBy: versionId1), let _ = try version(identifiedBy: versionId2) else { throw Error.missingVersion }
        
        var changes: [Value.Change] = []
        let diffs = try valuesMap.differences(between: versionId2, and: versionId1, withCommonAncestor: versionId1)
        for diff in diffs {
            switch diff.valueFork {
            case .inserted:
                let value = try self.value(id: diff.valueId, at: versionId2)!
                changes.append(.insert(value))
            case .removed:
                changes.append(.remove(diff.valueId))
            case .updated:
                let value = try self.value(id: diff.valueId, at: versionId2)!
                changes.append(.update(value))
            case .removedAndUpdated, .twiceInserted, .twiceRemoved, .twiceUpdated:
                fatalError("Should not be possible with only a single branch")
            }
        }
        
        return changes
    }
    
}


// MARK:- Storing and Fetching Versions

extension Store {
    
    fileprivate func store(_ version: Version) throws {
        let (dir, file) = fileSystemLocation(forVersionIdentifiedBy: version.id)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        let data = try encoder.encode(version)
        try data.write(to: file)
    }
    
    /// Returns all versions of a value with the given identifier in the history.
    /// Order is topological, from recent to ancient. No timestamp ordering has been applied
    /// This can be expensive, as it iterates all history.
    public func versionIds(for valueId: Value.ID) throws -> [Version.ID] {
        var existingVersions: Set<Version.ID> = []
        var valueVersions: [Version.ID] = []
        try queryHistory { history in
            for v in history {
                if let ref = try valueReference(id: valueId, at: v.id), !existingVersions.contains(ref.storedVersionId) {
                    valueVersions.append(ref.storedVersionId)
                    existingVersions.insert(ref.storedVersionId)
                }
            }
        }
        return valueVersions
    }
    
    
    /// Version ids found in store. This makes no use of the loaded history.
    internal func storedVersionIds(for valueId: Value.ID) throws -> [Version.ID] {
        let valueDirectoryURL = valuesDirectoryURL.appendingSplitPathComponent(valueId.stringValue)
        let enumerator = fileManager.enumerator(at: valueDirectoryURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])!
        let valueDirComponents = valueDirectoryURL.standardizedFileURL.pathComponents
        var versionIds: [Version.ID] = []
        for any in enumerator {
            var isDirectory: ObjCBool = true
            guard let url = any as? URL else { continue }
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue else { continue }
            guard url.pathExtension == "json" else { continue }
            let allComponents = url.standardizedFileURL.deletingPathExtension().pathComponents
            let versionComponents = allComponents[valueDirComponents.count...]
            let versionString = versionComponents.joined()
            versionIds.append(.init(versionString))
        }
        return versionIds
    }
    
    /// Versions found in store. This makes no use of the loaded history.
    fileprivate func storedVersions() throws -> [Version] {
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
    
    public func version(identifiedBy versionId: Version.ID) throws -> Version? {
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
    
    func fileSystemLocation(forVersionIdentifiedBy identifier: Version.ID) -> (directoryURL: URL, fileURL: URL) {
        let fileURL = versionsDirectoryURL.appendingSplitPathComponent(identifier.stringValue).appendingPathExtension("json")
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
