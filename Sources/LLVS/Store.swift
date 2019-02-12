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
        
        let valuesMapZone = Zone(rootDirectory: self.mapsDirectoryURL.appendingPathComponent(valuesMapName), fileExtension: "json")
        valuesMap = Map(zone: valuesMapZone)
        valuesZone = Zone(rootDirectory: self.valuesDirectoryURL, fileExtension: "json")

        try loadHistory()
    }
    
    private func loadHistory() throws {
        try historyAccessQueue.sync {
            for version in try versions() {
                try history.add(version, updatingPredecessorVersions: false)
            }
            for version in try versions() {
                try history.updateSuccessors(inPredecessorsOf: version)
            }
        }
    }
    
    public func queryHistory(in block: (History)->Void) {
        historyAccessQueue.sync {
            block(self.history)
        }
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
        // Update version in values
        let version = Version(predecessors: predecessors)
        
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
        try valuesMap.addVersion(version.identifier, basedOn: predecessors?.identifierOfFirst, applying: deltas)
        
        // Store version
        try store(version)
        
        // Add to history
        try historyAccessQueue.sync {
            try history.add(version, updatingPredecessorVersions: true)
        }
        
        return version
    }
    
    private func store(_ value: Value) throws {
        guard let zoneRef = value.zoneReference else { throw Error.attemptToStoreValueWithNoVersion }
        try valuesZone.store(value.data, for: zoneRef)
    }
}


// MARK:- Merging

extension Store {
    
    func merge(version firstVersionIdentifier: Version.Identifier, with secondVersionIdentifier: Version.Identifier, resolvingWith arbiter: MergeArbiter) throws -> Version {
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
        
        // Prepare merge
        let predecessors = Version.Predecessors(identifierOfFirst: firstVersionIdentifier, identifierOfSecond: secondVersionIdentifier)
        let diffs = try valuesMap.differences(between: firstVersionIdentifier, and: secondVersionIdentifier, withCommonAncestor: commonVersionIdentifier!)
        var merge = Merge(versions: (firstVersion!, secondVersion!), commonAncestor: commonVersion!)
        let forkTuples = diffs.map({ ($0.valueIdentifier, $0.valueFork) })
        merge.forksByValueIdentifier = .init(uniqueKeysWithValues: forkTuples)
        
        // Resolve with arbiter
        var changes = arbiter.changes(toResolve: merge, in: self)
        
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
                let ref = Value.Reference(identifier: diff.valueIdentifier, version: secondVersionIdentifier)
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
    
    public func value(_ valueIdentifier: Value.Identifier, prevailingAt versionIdentifier: Version.Identifier) throws -> Value? {
        let ref = try valuesMap.valueReferences(matching: .init(valueIdentifier.identifierString), at: versionIdentifier).first
        return try ref.flatMap { try value(valueIdentifier, storedAt: $0.version) }
    }
    
    internal func value(_ valueIdentifier: Value.Identifier, storedAt versionIdentifier: Version.Identifier) throws -> Value? {
        guard let data = try valuesZone.data(for: .init(key: valueIdentifier.identifierString, version: versionIdentifier)) else { return nil }
        let value = Value(identifier: valueIdentifier, version: versionIdentifier, data: data)
        return value
    }
    
    internal func values(_ valueIdentifier: Value.Identifier) throws -> [Value] {
        let versionIdentifiers = try valuesZone.versionIdentifiers(for: valueIdentifier.identifierString)
        return try versionIdentifiers.map { version in
            let data = try valuesZone.data(for: .init(key: valueIdentifier.identifierString, version: version))!
            return Value(identifier: valueIdentifier, version: version, data: data)
        }
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
        let valueDirectoryURL = fileManager.splitFilenameURL(forRoot: valuesDirectoryURL, name: valueIdentifier.identifierString)
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

}


// MARK:- File System Locations

fileprivate extension Store {
    
    func fileSystemLocation(forVersionIdentifiedBy identifier: Version.Identifier) -> (directoryURL: URL, fileURL: URL) {
        let fileURL = fileManager.splitFilenameURL(forRoot: versionsDirectoryURL, name: identifier.identifierString).appendingPathExtension("json")
        let directoryURL = fileURL.deletingLastPathComponent()
        return (directoryURL: directoryURL, fileURL: fileURL)
    }
}


// MARK:- Path Utilities

internal extension FileManager {
    
    func splitFilenameURL(forRoot rootDirectoryURL: URL, name: String, subDirectoryNameLength: UInt = 2) -> URL {
        guard name.count > subDirectoryNameLength else {
            return rootDirectoryURL.appendingPathComponent(name)
        }
        
        // Embed a subdirectory
        let index = name.index(name.startIndex, offsetBy: Int(subDirectoryNameLength))
        let prefix = String(name[..<index])
        let postfix = String(name[index...])
        let directory = rootDirectoryURL.appendingPathComponent(prefix).appendingPathComponent(postfix)
        
        return directory
    }
    
}
