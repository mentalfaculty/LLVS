//
//  Store.swift
//  llvs
//
//  Created by Drew McCormack on 31/10/2018.
//

import Foundation


// MARK:- Branch

public struct Branch: RawRepresentable {
    public let rawValue: String
    
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
    
    public init(randomizedNameBasedOn base: String = "") {
        let separator = base.isEmpty ? "" : "_"
        self.rawValue = "\(base)\(separator)\(UUID().uuidString)"
    }
}


// MARK:- Store

public final class Store {
    
    public enum Error: Swift.Error {
        case missingVersion
        case attemptToLocateUnversionedValue
        case attemptToStoreValueWithNoVersion
        case noCommonAncestor(firstVersion: Version.ID, secondVersion: Version.ID)
        case unresolvedConflict(valueId: Value.ID, valueFork: Value.Fork)
        case attemptToAddExistingVersion(Version.ID)
        case attemptToAddVersionWithNonexistingPredecessors(Version)
        case accessToCompressedVersion(Version.ID)
        case mergeWithCompressedAncestor(versionId: Version.ID, compressedAncestorId: Version.ID)
    }
    
    public let rootDirectoryURL: URL
    public let valuesDirectoryURL: URL
    public let versionsDirectoryURL: URL
    public let mapsDirectoryURL: URL
    public let valuesMapDirectoryURL: URL
    
    public let storage: Storage

    private lazy var valuesZone: Zone = {
        return try! storage.makeValuesZone(in: self)
    }()
    
    private let valuesMapName = "__llvs_values"
    private lazy var valuesMap: Map = {
        let valuesMapZone = try! self.storage.makeMapZone(for: .valuesByVersion, in: self)
        return Map(zone: valuesMapZone)
    }()
    
    private let history = History()
    private let historyAccessQueue = DispatchQueue(label: "llvs.dispatchQueue.historyaccess")

    private var compactionInfo: CompactionInfo = CompactionInfo()
    private var compactionInfoFileURL: URL { rootDirectoryURL.appendingPathComponent("compaction.json") }
    
    fileprivate let fileManager = FileManager()
    
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
        compactionInfo = loadCompactionInfo()
        if !compactionInfo.compressedVersionIds.isEmpty {
            // Remove compressed versions from in-memory history (they may have been loaded
            // if their JSON files haven't been cleaned up yet)
            historyAccessQueue.sync {
                for versionId in compactionInfo.compressedVersionIds {
                    history.remove(versionId)
                }
            }
        }
        try resumeCleanupIfNeeded()
    }

    public var compressedVersionIdentifiers: Set<Version.ID> {
        return compactionInfo.compressedVersionIds
    }

    public func isCompressedVersion(_ versionId: Version.ID) -> Bool {
        return compactionInfo.compressedVersionIds.contains(versionId)
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
    @discardableResult public func makeVersion(basedOnPredecessor versionId: Version.ID?, inserting insertedValues: [Value] = [], updating updatedValues: [Value] = [], removing removedIds: [Value.ID] = [], metadata: Version.Metadata = [:]) throws -> Version {
        let predecessors = versionId.flatMap { Version.Predecessors(idOfFirst: $0, idOfSecond: nil) }
        let inserts: [Value.Change] = insertedValues.map { .insert($0) }
        let updates: [Value.Change] = updatedValues.map { .update($0) }
        let removes: [Value.Change] = removedIds.map { .remove($0) }
        return try makeVersion(basedOn: predecessors, storing: inserts+updates+removes, metadata: metadata)
    }
    
    @discardableResult public func makeVersion(basedOnPredecessor version: Version.ID?, storing changes: [Value.Change], metadata: Version.Metadata = [:]) throws -> Version {
        let predecessors = version.flatMap { Version.Predecessors(idOfFirst: $0, idOfSecond: nil) }
        return try makeVersion(basedOn: predecessors, storing: changes, metadata: metadata)
    }
    
    /// Changes must include all updates to the map of the first predecessor. If necessary, preserves should be included to bring values
    /// from the second predecessor into the first predecessor map.
    @discardableResult internal func makeVersion(basedOn predecessors: Version.Predecessors?, storing changes: [Value.Change], metadata: Version.Metadata = [:]) throws -> Version {
        let version = Version(predecessors: predecessors, valueDataSize: changes.valueDataSize, metadata: metadata)
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
        var valueDataSize: Int64 = 0
        for change in changes {
            switch change {
            case .insert(let value), .update(let value):
                var newValue = value
                newValue.storedVersionId = version.id
                try self.store(newValue)
                valueDataSize += Int64(newValue.data.count)
            case .remove, .preserve, .preserveRemoval:
                continue
            }
        }
        
        // Update values map
        let deltas: [Map.Delta] = changes.map { change in
            switch change {
            case .insert(let value), .update(let value):
                let valueRef = Value.Reference(valueId: value.id, storedVersionId: version.id)
                var delta = Map.Delta(key: Map.Key(value.id.rawValue))
                delta.addedValueReferences = [valueRef]
                return delta
            case .remove(let valueId), .preserveRemoval(let valueId):
                var delta = Map.Delta(key: Map.Key(valueId.rawValue))
                delta.removedValueIdentifiers = [valueId]
                return delta
            case .preserve(let valueRef):
                var delta = Map.Delta(key: Map.Key(valueRef.valueId.rawValue))
                delta.addedValueReferences = [valueRef]
                return delta
            }
        }
        try valuesMap.addVersion(version.id, basedOn: version.predecessors?.idOfFirst, applying: deltas)
        
        // Store version
        var versionWithDataSize = version
        versionWithDataSize.valueDataSize = valueDataSize
        try store(versionWithDataSize)
        
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
        return try valuesMap.valueReferences(matching: .init(valueId.rawValue), at: versionId).first
    }
    
    public func valueReferences(at version: Version.ID) throws -> [Value.Reference] {
        var refs: [Value.Reference] = []
        try enumerate(version: version) { ref in
            refs.append(ref)
        }
        return refs
    }
    
    /// Convenient method to avoid having to create id types
    public func value(idString valueIdString: String, at versionId: Version.ID) throws -> Value? {
        return try value(id: .init(valueIdString), at: versionId)
    }
    
    public func value(id valueId: Value.ID, at versionId: Version.ID) throws -> Value? {
        guard !isCompressedVersion(versionId) else {
            throw Error.accessToCompressedVersion(versionId)
        }
        let ref = try valueReference(id: valueId, at: versionId)
        return try ref.flatMap { try value(id: valueId, storedAt: $0.storedVersionId) }
    }
    
    public func value(id valueId: Value.ID, storedAt versionId: Version.ID) throws -> Value? {
        guard let data = try valuesZone.data(for: .init(key: valueId.rawValue, version: versionId)) else { return nil }
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
    
    public enum MergeHeadSelection {
        case all
        case allExceptBranches
        case allUnbranchedAndSpecificBranches([Branch])
        case specificBranchesOnly([Branch])
    }
    
    /// Whether there is more than one head
    public var hasMultipleHeads: Bool {
        var result: Bool = false
        queryHistory { history in
            result = history.headIdentifiers.count > 1
        }
        return result
    }
    
    /// Finds any heads that have the branch in the metadata.
    public func heads(withBranch branch: Branch) -> [Version.ID] {
        var result: [Version.ID] = []
        queryHistory { history in
            let heads = history.headIdentifiers
            result = heads.filter { id in
                let version = history.version(identifiedBy: id)!
                return branch.rawValue == version.metadata[.branch]?.value()
            }
        }
        return result
    }
    
    /// Merges heads into the version passed, which is usually a head itself. This is a convenience
    /// to save looping through all heads.
    /// If the version ends up being changed by the merging, the new version is returned, otherwise nil.
    public func mergeHeads(into version: Version.ID, resolvingWith arbiter: MergeArbiter, headSelection: MergeHeadSelection = .allExceptBranches, metadata: Version.Metadata = [:]) -> Version.ID? {
        var heads: Set<Version.ID> = []
        var versionsById: [Version.ID:Version] = [:]
        queryHistory { history in
            heads = history.headIdentifiers
            versionsById = .init(uniqueKeysWithValues: heads.map({ ($0, history.version(identifiedBy: $0)!) }))
        }
        heads.remove(version)
        
        heads = heads.filter { id in
            let version = versionsById[id]!
            let branch: String? = version.metadata[.branch]?.value()
            switch headSelection {
            case .all:
                return true
            case .allExceptBranches:
                return branch == nil
            case .allUnbranchedAndSpecificBranches(let branches):
                return branch == nil || branches.map({ $0.rawValue }).contains(branch)
            case .specificBranchesOnly(let branches):
                return branches.map({ $0.rawValue }).contains(branch)
            }
        }
        
        guard !heads.isEmpty else { return nil }
        
        var versionId: Version.ID = version
        for otherHead in heads {
            let newVersion = try! merge(version: versionId, with: otherHead, resolvingWith: arbiter, metadata: metadata)
            versionId = newVersion.id
        }
        
        return versionId
    }
    
    /// Will choose between a three way merge, and a two way merge, based on whether a common ancestor is found.
    public func merge(version firstVersionIdentifier: Version.ID, with secondVersionIdentifier: Version.ID, resolvingWith arbiter: MergeArbiter, metadata: Version.Metadata = [:]) throws -> Version {
        do {
            return try mergeRelated(version: firstVersionIdentifier, with: secondVersionIdentifier, resolvingWith: arbiter, metadata: metadata)
        } catch Error.noCommonAncestor {
            return try mergeUnrelated(version: firstVersionIdentifier, with: secondVersionIdentifier, resolvingWith: arbiter, metadata: metadata)
        }
    }
    
    /// Two-way merge between two versions that have no common ancestry. Effectively we assume an empty common ancestor,
    /// so that all changes are inserts, or conflicting twiceInserts.
    public func mergeUnrelated(version firstVersionIdentifier: Version.ID, with secondVersionIdentifier: Version.ID, resolvingWith arbiter: MergeArbiter, metadata: Version.Metadata = [:]) throws -> Version {
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
    public func mergeRelated(version firstVersionIdentifier: Version.ID, with secondVersionIdentifier: Version.ID, resolvingWith arbiter: MergeArbiter, metadata: Version.Metadata = [:]) throws -> Version {
        var firstVersion, secondVersion, commonVersion: Version?
        var commonVersionIdentifier: Version.ID?
        try historyAccessQueue.sync {
            commonVersionIdentifier = try history.greatestCommonAncestor(ofVersionsIdentifiedBy: (firstVersionIdentifier, secondVersionIdentifier))
            guard commonVersionIdentifier != nil else {
                throw Error.noCommonAncestor(firstVersion: firstVersionIdentifier, secondVersion: secondVersionIdentifier)
            }
            if isCompressedVersion(commonVersionIdentifier!) {
                throw Error.mergeWithCompressedAncestor(versionId: firstVersionIdentifier, compressedAncestorId: commonVersionIdentifier!)
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
    private func merge(_ firstVersion: Version, and secondVersion: Version, withCommonAncestor commonAncestor: Version?, resolvingWith arbiter: MergeArbiter, metadata: Version.Metadata = [:]) throws -> Version {
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
        guard !isCompressedVersion(versionId) else {
            throw Error.accessToCompressedVersion(versionId)
        }
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
        try autoreleasepool {
            let (dir, file) = fileSystemLocation(forVersionIdentifiedBy: version.id)
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
            let data = try JSONEncoder().encode(version)
            try data.write(to: file)
        }
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
        let valueDirectoryURL = valuesDirectoryURL.appendingSplitPathComponent(valueId.rawValue)
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
        try autoreleasepool {
            let enumerator = fileManager.enumerator(at: versionsDirectoryURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])!
            var versions: [Version] = []
            let decoder = JSONDecoder()
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


// MARK:- Compaction

extension Store {

    /// Compacts old history by collapsing all versions before a cutoff into a single baseline snapshot.
    /// Returns the baseline version ID, or nil if compaction could not proceed.
    @discardableResult public func compact(beforeDate cutoffDate: Date = Date(timeIntervalSinceNow: -7*24*3600), minRetainedVersions: Int = 50) throws -> Version.ID? {
        // Find compaction boundary
        guard let (compactionPointId, compressedSet) = try findCompactionBoundary(beforeDate: cutoffDate, minRetainedVersions: minRetainedVersions) else {
            return nil
        }

        // Phase 1: PREPARE
        let baselineId = Version.ID()
        var compactionPointTimestamp: TimeInterval = Date().timeIntervalSinceReferenceDate
        queryHistory { history in
            if let v = history.version(identifiedBy: compactionPointId) {
                compactionPointTimestamp = v.timestamp
            }
        }

        // Enumerate all values at the compaction point and copy them to the baseline
        var deltas: [Map.Delta] = []
        try valuesMap.enumerateValueReferences(forVersionIdentifiedBy: compactionPointId) { ref in
            let data = try valuesZone.data(for: ZoneReference(key: ref.valueId.rawValue, version: ref.storedVersionId))
            if let data = data {
                let baselineRef = ZoneReference(key: ref.valueId.rawValue, version: baselineId)
                try valuesZone.store(data, for: baselineRef)
            }
            let newValueRef = Value.Reference(valueId: ref.valueId, storedVersionId: baselineId)
            var delta = Map.Delta(key: Map.Key(ref.valueId.rawValue))
            delta.addedValueReferences = [newValueRef]
            deltas.append(delta)
        }

        // Build baseline Map (no predecessor — fresh root)
        try valuesMap.addVersion(baselineId, basedOn: nil, applying: deltas)

        // Write baseline Version JSON
        var baselineVersion = Version(id: baselineId, predecessors: nil, valueDataSize: 0, metadata: [:])
        baselineVersion.timestamp = compactionPointTimestamp
        try store(baselineVersion)

        // Find children of compaction point that are NOT in the compressed set.
        // Update their predecessor pointers to reference the baseline instead.
        var childrenOfCompactionPoint: [Version] = []
        queryHistory { history in
            if let v = history.version(identifiedBy: compactionPointId) {
                for successorId in v.successors.ids where !compressedSet.contains(successorId) {
                    if let successor = history.version(identifiedBy: successorId) {
                        childrenOfCompactionPoint.append(successor)
                    }
                }
            }
        }

        for child in childrenOfCompactionPoint {
            var updatedChild = child
            if var preds = updatedChild.predecessors {
                if preds.idOfFirst == compactionPointId {
                    preds.idOfFirst = baselineId
                }
                if preds.idOfSecond == compactionPointId {
                    preds.idOfSecond = baselineId
                }
                updatedChild.predecessors = preds
            }
            try store(updatedChild)
        }

        // Phase 2: COMMIT
        compactionInfo.baselineVersionId = baselineId
        compactionInfo.compressedVersionIds.formUnion(compressedSet)
        compactionInfo.pendingCleanup = true
        try saveCompactionInfo()

        // Update in-memory History
        try historyAccessQueue.sync {
            try history.add(baselineVersion, updatingPredecessorVersions: false)

            // Update children predecessor pointers in memory
            for child in childrenOfCompactionPoint {
                var updatedChild = child
                if var preds = updatedChild.predecessors {
                    if preds.idOfFirst == compactionPointId {
                        preds.idOfFirst = baselineId
                    }
                    if preds.idOfSecond == compactionPointId {
                        preds.idOfSecond = baselineId
                    }
                    updatedChild.predecessors = preds
                }
                // Re-add the updated child by removing and re-adding
                // Actually, we need to directly update the version in history
                // Since History doesn't have an update method, we remove and re-add
                history.remove(updatedChild.id)
                try history.add(updatedChild, updatingPredecessorVersions: false)
            }

            // Update successor info for baseline
            try history.updateSuccessors(inPredecessorsOf: baselineVersion)
            for child in childrenOfCompactionPoint {
                try history.updateSuccessors(inPredecessorsOf: child)
            }

            // Remove compressed versions
            for versionId in compressedSet {
                history.remove(versionId)
            }
        }

        // Phase 3: CLEANUP
        try performCleanup(forCompressedVersionIds: compressedSet)

        compactionInfo.pendingCleanup = false
        try saveCompactionInfo()

        return baselineId
    }

    private func findCompactionBoundary(beforeDate cutoffDate: Date, minRetainedVersions: Int) throws -> (Version.ID, Set<Version.ID>)? {
        let cutoffTimestamp = cutoffDate.timeIntervalSinceReferenceDate

        var result: (Version.ID, Set<Version.ID>)?
        try queryHistory { history in
            let heads = history.headIdentifiers
            guard !heads.isEmpty else { return }

            if heads.count > 1 {
                // Multiple heads: find their GCA as the bottleneck
                guard let gca = try history.greatestCommonAncestor(ofAll: heads) else { return }
                guard let gcaVersion = history.version(identifiedBy: gca) else { return }
                guard gcaVersion.timestamp < cutoffTimestamp else { return }

                // Check we retain enough versions above the GCA
                let ancestors = history.allAncestors(of: gca)
                let totalVersionCount = history.allVersionIdentifiers.count
                let compressedCount = ancestors.count + 1 // ancestors + GCA itself
                let retained = totalVersionCount - compressedCount
                guard retained >= minRetainedVersions else { return }

                var compressedSet = ancestors
                compressedSet.insert(gca)
                result = (gca, compressedSet)
            } else {
                // Single head: walk backward to find a bottleneck
                let headId = heads.first!
                var versionsSkipped = 0
                var foundBottleneck: Version.ID?

                // Walk backward through history
                for version in history {
                    if version.id == headId { continue }
                    versionsSkipped += 1

                    if versionsSkipped >= minRetainedVersions && version.timestamp < cutoffTimestamp {
                        // This version is old enough and we've skipped enough.
                        let succCount = version.successors.ids.count
                        if succCount <= 1 {
                            foundBottleneck = version.id
                            break
                        }
                    }
                }

                guard let bottleneck = foundBottleneck else { return }
                var compressedSet = history.allAncestors(of: bottleneck)
                compressedSet.insert(bottleneck)
                result = (bottleneck, compressedSet)
            }
        }
        return result
    }

    private func performCleanup(forCompressedVersionIds compressedIds: Set<Version.ID>) throws {
        // Collect all value storedVersionIds that are still referenced by versions
        // above the boundary, so we don't delete data that's still needed.
        var referencedStoredVersionIds = Set<Version.ID>()
        var aboveBoundaryVersionIds: [Version.ID] = []
        queryHistory { history in
            aboveBoundaryVersionIds = history.allVersionIdentifiers.filter { !compressedIds.contains($0) }
        }
        for versionId in aboveBoundaryVersionIds {
            try valuesMap.enumerateValueReferences(forVersionIdentifiedBy: versionId) { ref in
                if compressedIds.contains(ref.storedVersionId) {
                    referencedStoredVersionIds.insert(ref.storedVersionId)
                }
            }
        }

        // Only delete value data for compressed versions that are NOT still referenced
        let safeToDeleteValueData = compressedIds.subtracting(referencedStoredVersionIds)
        for versionId in safeToDeleteValueData {
            try valuesZone.deleteAll(forVersionIdentifiedBy: versionId)
        }

        // Note: Map nodes for compressed versions are intentionally kept.
        // Versions above the compaction boundary may have Map subnodes that
        // reference compressed versions. Deleting them would break the Map trie.

        // Delete version JSON files for all compressed versions
        for versionId in compressedIds {
            let (_, fileURL) = fileSystemLocation(forVersionIdentifiedBy: versionId)
            try? fileManager.removeItem(at: fileURL)
        }

        // Purge caches
        valuesMap.purgeCache()
    }

    private func loadCompactionInfo() -> CompactionInfo {
        guard let data = try? Data(contentsOf: compactionInfoFileURL),
              let info = try? JSONDecoder().decode(CompactionInfo.self, from: data) else {
            return CompactionInfo()
        }
        return info
    }

    private func saveCompactionInfo() throws {
        let data = try JSONEncoder().encode(compactionInfo)
        try data.write(to: compactionInfoFileURL, options: .atomic)
    }

    private func resumeCleanupIfNeeded() throws {
        guard compactionInfo.pendingCleanup else { return }
        try performCleanup(forCompressedVersionIds: compactionInfo.compressedVersionIds)
        compactionInfo.pendingCleanup = false
        try saveCompactionInfo()
    }
}


// MARK:- File System Locations

fileprivate extension Store {
    
    func fileSystemLocation(forVersionIdentifiedBy identifier: Version.ID) -> (directoryURL: URL, fileURL: URL) {
        let fileURL = versionsDirectoryURL.appendingSplitPathComponent(identifier.rawValue).appendingPathExtension("json")
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
