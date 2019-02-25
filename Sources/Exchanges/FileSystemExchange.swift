//
//  FileSystemExchange.swift
//  LLVS
//
//  Created by Drew McCormack on 25/02/2019.
//

import Foundation

public class FileSystemExchange: Exchange {
    
    public let rootDirectoryURL: URL
    public var versionsDirectory: URL { return rootDirectoryURL.appendingPathComponent("versions") }
    public var changesDirectory: URL { return rootDirectoryURL.appendingPathComponent("changes") }

    private let fileManager = FileManager()
    
    init(rootDirectoryURL: URL) {
        self.rootDirectoryURL = rootDirectoryURL
        try? fileManager.createDirectory(at: rootDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        try? fileManager.createDirectory(at: versionsDirectory, withIntermediateDirectories: true, attributes: nil)
        try? fileManager.createDirectory(at: changesDirectory, withIntermediateDirectories: true, attributes: nil)
    }
    
    public func retrieveRemoteVersionIdentifiers(executingUponCompletion completionHandler: @escaping (ExchangeResult<[Version.Identifier]>) -> Void) {
        
    }
    
    public func retrieveRemoteVersion(identifiedBy versionIdentifier: Version.Identifier, executingUponCompletion completionHandler: @escaping (ExchangeResult<Version>) -> Void) {
        
    }
    
    public func retrieveRemoteChanges(forVersionIdentifiedBy versionIdentifier: Version.Identifier, executingUponCompletion completionHandler: @escaping (ExchangeResult<Value.Change>) -> Void) {
        
    }
    
    
}
