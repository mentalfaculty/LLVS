//
//  Store.swift
//  llvs
//
//  Created by Drew McCormack on 31/10/2018.
//

import Foundation

open class Store {
    
    public let rootDirectoryURL: URL
    
    public let valuesDirectoryURL: URL
    public let versionsDirectoryURL: URL
    public let viewsDirectoryURL: URL
    
    private let fileManager = FileManager()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    public init(rootDirectoryURL: URL) {
        self.rootDirectoryURL = rootDirectoryURL
        self.valuesDirectoryURL = rootDirectoryURL.appendingPathComponent("values")
        self.versionsDirectoryURL = rootDirectoryURL.appendingPathComponent("versions")
        self.viewsDirectoryURL = rootDirectoryURL.appendingPathComponent("views")
        try? fileManager.createDirectory(at: self.rootDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        try? fileManager.createDirectory(at: self.valuesDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        try? fileManager.createDirectory(at: self.versionsDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        try? fileManager.createDirectory(at: self.viewsDirectoryURL, withIntermediateDirectories: true, attributes: nil)
    }
        
    private func createDirectory(_ relativePath: String) {
        try? fileManager.createDirectory(atPath: relativePath, withIntermediateDirectories: true, attributes: nil)
    }
    
    private func directoryURL(for identifier: Value.Identifier) -> URL {
        let identifier = identifier.identifierString
        let index = identifier.index(identifier.startIndex, offsetBy: 2)
        let prefix = String(identifier[..<index])
        let postfix = String(identifier[index...])
        let directory = valuesDirectoryURL.appendingPathComponent(prefix).appendingPathComponent(postfix)
        return directory
    }
    
    public func addVersion(includingUpdatedValues values: inout [Value], basedOn predecessors: Version.Predecessors?) throws -> Version {
        let version = Version(predecessors: predecessors)

        values = values.map { value in
            var newValue = value
            newValue.version = version
            return newValue
        }
        
        try values.forEach { value in
            try self.store(value)
        }
        
        store(version)
        
        return version
    }
    
    private func store(_ value: Value) throws {
        let directoryURL = self.directoryURL(for: value.identifier)
        let file = directoryURL.appendingPathComponent(value.version!.identifier.identifierString + ".json")
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        let data = try encoder.encode(value)
        try data.write(to: file)
    }
    
    private func store(_ version: Version) {
        // TBW
    }
    
}
