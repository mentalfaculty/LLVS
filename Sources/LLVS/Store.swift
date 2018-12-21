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
        case attemptToLocateUnversionedValue
        case attemptToStoreValueWithNoVersion
        case noCommonAncestor(firstVersion: Version.Identifier, secondVersion: Version.Identifier)
    }
    
    public let rootDirectoryURL: URL
    public let valuesDirectoryURL: URL
    public let versionsDirectoryURL: URL
    public let mapsDirectoryURL: URL

    private let valuesZone: Zone
    
    private let valuesMapName = "__llvs_values"
    private let valuesMap: Map
    
    public private(set) var history = History()
    
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
        for version in try versions() {
            try history.add(version, updatingPredecessorVersions: false)
        }
    }
    
}


// MARK:- Storing Values and Versions

extension Store {
    
    @discardableResult public func addVersion(basedOn predecessors: Version.Predecessors?, storing storedValues: inout [Value], removing removedIdentifiers: [Value.Identifier]) throws -> Version {
        // Update version in values
        let version = Version(predecessors: predecessors)
        storedValues = storedValues.map { value in
            var newValue = value
            newValue.version = version.identifier
            return newValue
        }
        
        // Store values
        try storedValues.forEach { value in
            try self.store(value)
        }
        
        // Update values map
        let storedDeltas: [Map.Delta] = storedValues.map { value in
            let valueId = value.identifier
            var delta = Map.Delta(key: Map.Key(valueId.identifierString))
            delta.addedValueIdentifiers = [valueId]
            return delta
        }
        let removedDeltas: [Map.Delta] = removedIdentifiers.map { valueIdentifier in
            var delta = Map.Delta(key: Map.Key(valueIdentifier.identifierString))
            delta.removedValueIdentifiers = [valueIdentifier]
            return delta
        }
        try valuesMap.addVersion(version.identifier, basedOn: predecessors?.identifierOfFirst, applying: storedDeltas + removedDeltas)
        
        // Store version
        try store(version)
        
        // Add to history
        try history.add(version, updatingPredecessorVersions: true)
        
        return version
    }
    
    private func store(_ value: Value) throws {
        guard let zoneRef = value.zoneReference else { throw Error.attemptToStoreValueWithNoVersion }
        try valuesZone.store(value.data, for: zoneRef)
    }
}


// MARK:- Merging

extension Store {
    
    func merge(version firstVersion: Version.Identifier, with secondVersion: Version.Identifier, resolvingWith resolver: Resolver) throws -> Version {
        guard let commonAncestor = try history.greatestCommonAncestor(ofVersionsIdentifiedBy: (firstVersion, secondVersion)) else {
            throw Error.noCommonAncestor(firstVersion: firstVersion, secondVersion: secondVersion)
        }
        
        let predecessors = Version.Predecessors(identifierOfFirst: firstVersion, identifierOfSecond: secondVersion)
        let diffs = try valuesMap.differences(between: firstVersion, and: secondVersion, withCommonAncestor: commonAncestor)
        var merge = Merge()
        for diff in diffs {
//            switch diff.versionFork {
//            case .exclusiveToFirst(let version):
//            case .exclusiveToSecond(let version):
//            case .conflict(let version1, version2):
//            }
        }
        var updatedValues: [Value] = []
        let removedIdentifiers: [Value.Identifier] = []
        return try addVersion(basedOn: predecessors, storing: &updatedValues, removing: removedIdentifiers)
    }
    
}


// MARK:- Fetching Values

extension Store {
    
    public func value(_ valueIdentifier: Value.Identifier, prevailingAt versionIdentifier: Version.Identifier) throws -> Value? {
        let candidateVersionIdentifiers = try versionIdentifiers(for: valueIdentifier)
        let prevailingVersion = history.version(prevailingFromCandidates: candidateVersionIdentifiers, at: versionIdentifier)
        return try prevailingVersion.flatMap {
            try value(valueIdentifier, storedAt: $0.identifier)
        }
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
        let fileURL = fileManager.splitFilenameURL(forRoot: versionsDirectoryURL, name: identifier.identifierString)
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
