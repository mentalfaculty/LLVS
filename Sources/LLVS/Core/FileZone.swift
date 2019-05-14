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
    
    private let uncachableDataSizeLimit = 10000 // 10KB
    private let cache: Cache<Data> = .init()
    
    fileprivate let fileManager = FileManager()
    
    init(rootDirectory: URL, fileExtension: String) {
        self.rootDirectory = rootDirectory.resolvingSymlinksInPath()
        try? fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true, attributes: nil)
        self.fileExtension = fileExtension
    }
    
    private func cacheIfNeeded(_ data: Data, for reference: ZoneReference) {
        if data.count < uncachableDataSizeLimit {
            cache.setValue(data, for: reference)
        }
    }
    
    internal func store(_ data: Data, for reference: ZoneReference) throws {
        let (dir, file) = try fileSystemLocation(for: reference)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        try data.write(to: file)
        cacheIfNeeded(data, for: reference)
    }
    
    internal func data(for reference: ZoneReference) throws -> Data? {
        if let data = cache.value(for: reference) { return data }
        let (_, file) = try fileSystemLocation(for: reference)
        guard let data = try? Data(contentsOf: file) else { return nil }
        cacheIfNeeded(data, for: reference)
        return data
    }
    
    func fileSystemLocation(for reference: ZoneReference) throws -> (directoryURL: URL, fileURL: URL) {
        let safeKey = reference.key.replacingOccurrences(of: "/", with: "LLVSSLASH").replacingOccurrences(of: ":", with: "LLVSCOLON")
        let valueDirectoryURL = rootDirectory.appendingSplitPathComponent(safeKey)
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
