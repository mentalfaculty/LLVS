//
//  Store.swift
//  llvs
//
//  Created by Drew McCormack on 31/10/2018.
//

import Foundation

public final class Store {
    
    enum Error: Swift.Error {
        case attemptToLocateUnversionedValue
        case attemptToStoreValueWithNoVersion
    }
    
    public let rootDirectoryURL: URL
    public let valuesDirectoryURL: URL
    public let versionsDirectoryURL: URL
    public let filtersDirectoryURL: URL

    private let valuesZone: Zone
    
    public private(set) var history = History()
    
    fileprivate let fileManager = FileManager()
    fileprivate let encoder = JSONEncoder()
    fileprivate let decoder = JSONDecoder()
    
    public init(rootDirectoryURL: URL) throws {
        self.rootDirectoryURL = rootDirectoryURL.resolvingSymlinksInPath()
        self.valuesDirectoryURL = rootDirectoryURL.appendingPathComponent("values")
        self.versionsDirectoryURL = rootDirectoryURL.appendingPathComponent("versions")
        self.filtersDirectoryURL = rootDirectoryURL.appendingPathComponent("maps")
        try? fileManager.createDirectory(at: self.rootDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        try? fileManager.createDirectory(at: self.valuesDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        try? fileManager.createDirectory(at: self.versionsDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        try? fileManager.createDirectory(at: self.filtersDirectoryURL, withIntermediateDirectories: true, attributes: nil)
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
    
    @discardableResult public func addVersion(basedOn predecessors: Version.Predecessors?, storing values: inout [Value]) throws -> Version {
        let version = Version(predecessors: predecessors)
        values = values.map { value in
            var newValue = value
            newValue.version = version
            return newValue
        }
        
        try values.forEach { value in
            try self.store(value)
        }
        
        try store(version)
        
        try history.add(version, updatingPredecessorVersions: true)
        
        return version
    }
    
    private func store(_ value: Value) throws {
        guard let zoneRef = value.zoneReference else { throw Error.attemptToStoreValueWithNoVersion }
        let data = try encoder.encode(value)
        try valuesZone.store(data, for: zoneRef)
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
        let value = try decoder.decode(Value.self, from: data)
        return value
    }
    
    internal func values(_ valueIdentifier: Value.Identifier) throws -> [Value] {
        let versionIdentifiers = try valuesZone.versionIdentifiers(for: valueIdentifier.identifierString)
        return try versionIdentifiers.map { version in
            let data = try valuesZone.data(for: .init(key: valueIdentifier.identifierString, version: version))!
            return try decoder.decode(Value.self, from: data)
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
            guard let url = any as? URL, !url.hasDirectoryPath else { continue }
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
            guard let url = any as? URL, !url.hasDirectoryPath else { continue }
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
