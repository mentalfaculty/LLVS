//
//  Zone.swift
//  LLVS
//
//  Created by Drew McCormack on 02/12/2018.
//

import Foundation

internal final class Zone {
    
    let rootDirectory: URL
    let fileExtension: String
    
    fileprivate let fileManager = FileManager()
    
    struct Reference: Codable, Hashable {
        var key: String
        var version: Version.Identifier
    }
    
    init(rootDirectory: URL, fileExtension: String) {
        self.rootDirectory = rootDirectory.resolvingSymlinksInPath()
        self.fileExtension = fileExtension
    }

    internal func store(_ data: Data, for reference: Reference) throws {
        let (dir, file) = try fileSystemLocation(for: reference)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        try data.write(to: file)
    }
    
    internal func data(for reference: Reference) throws -> Data? {
        let (_, file) = try fileSystemLocation(for: reference)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return data
    }
    
    internal func versionIdentifiers(for key: String) throws -> [Version.Identifier] {
        let valueDirectoryURL = fileManager.splitFilenameURL(forRoot: rootDirectory, name: key)
        let valueDirLength = valueDirectoryURL.path.count
        let enumerator = fileManager.enumerator(at: valueDirectoryURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])!
        var versions: [Version.Identifier] = []
        let slash = Character("/")
        for any in enumerator {
            guard let url = any as? URL, !url.hasDirectoryPath else { continue }
            let path = url.resolvingSymlinksInPath().deletingPathExtension().path
            let index = path.index(path.startIndex, offsetBy: Int(valueDirLength))
            let version = String(path[index...]).filter { $0 != slash }
            versions.append(Version.Identifier(version))
        }
        return versions
    }
    
    func fileSystemLocation(for reference: Reference) throws -> (directoryURL: URL, fileURL: URL) {
        let valueDirectoryURL = fileManager.splitFilenameURL(forRoot: rootDirectory, name: reference.key)
        let versionName = reference.version.identifierString + "." + fileExtension
        let fileURL = fileManager.splitFilenameURL(forRoot: valueDirectoryURL, name: versionName, subDirectoryNameLength: 1)
        let directoryURL = fileURL.deletingLastPathComponent()
        return (directoryURL: directoryURL, fileURL: fileURL)
    }
        
}
