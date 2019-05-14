//
//  FileZone.swift
//  LLVS
//
//  Created by Drew McCormack on 14/05/2019.
//

import Foundation

internal final class FileZone: Zone {
    
    let rootDirectory: URL
    let fileExtension: String
    
    fileprivate let fileManager = FileManager()
    
    init(rootDirectory: URL, fileExtension: String) {
        self.rootDirectory = rootDirectory.resolvingSymlinksInPath()
        try? fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true, attributes: nil)
        self.fileExtension = fileExtension
    }
    
    internal func store(_ data: Data, for reference: ZoneReference) throws {
        let (dir, file) = try fileSystemLocation(for: reference)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        try data.write(to: file)
    }
    
    internal func data(for reference: ZoneReference) throws -> Data? {
        let (_, file) = try fileSystemLocation(for: reference)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return data
    }
    
    func fileSystemLocation(for reference: ZoneReference) throws -> (directoryURL: URL, fileURL: URL) {
        let valueDirectoryURL = rootDirectory.appendingSplitPathComponent(reference.key)
        let versionName = reference.version.identifierString + "." + fileExtension
        let fileURL = valueDirectoryURL.appendingSplitPathComponent(versionName, prefixLength: 1)
        let directoryURL = fileURL.deletingLastPathComponent()
        return (directoryURL: directoryURL, fileURL: fileURL)
    }
    
    internal func versionIdentifiers(for key: String) throws -> [Version.Identifier] {
        let valueDirectoryURL = rootDirectory.appendingSplitPathComponent(key)
        let valueDirLength = valueDirectoryURL.path.count
        let enumerator = fileManager.enumerator(at: valueDirectoryURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])!
        var versions: [Version.Identifier] = []
        let slash = Character("/")
        for any in enumerator {
            var isDirectory: ObjCBool = true
            guard let url = any as? URL else { continue }
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue else { continue }
            let path = url.resolvingSymlinksInPath().deletingPathExtension().path
            let index = path.index(path.startIndex, offsetBy: Int(valueDirLength))
            let version = String(path[index...]).filter { $0 != slash }
            versions.append(Version.Identifier(version))
        }
        return versions
    }
}
