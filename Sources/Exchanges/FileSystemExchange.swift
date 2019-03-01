//
//  FileSystemExchange.swift
//  LLVS
//
//  Created by Drew McCormack on 25/02/2019.
//

import Foundation

public class FileSystemExchange: NSObject, Exchange {
    
    public enum Error: Swift.Error {
        case versionFileInvalid
        case changesFileInvalid
    }
    
    public weak var client: ExchangeClient?
    
    public let rootDirectoryURL: URL
    public var versionsDirectory: URL { return rootDirectoryURL.appendingPathComponent("versions") }
    public var changesDirectory: URL { return rootDirectoryURL.appendingPathComponent("changes") }

    private let fileManager = FileManager()
    fileprivate let queue = OperationQueue()

    init(rootDirectoryURL: URL) {
        self.rootDirectoryURL = rootDirectoryURL
        super.init()
        try? fileManager.createDirectory(at: rootDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        try? fileManager.createDirectory(at: versionsDirectory, withIntermediateDirectories: true, attributes: nil)
        try? fileManager.createDirectory(at: changesDirectory, withIntermediateDirectories: true, attributes: nil)
    }
    
    public func retrieveAllVersionIdentifiers(executingUponCompletion completionHandler: @escaping (ExchangeResult<[Version.Identifier]>) -> Void) {
        coordinateFileAccess(.read, completionHandler: completionHandler) {
            let contents = try self.fileManager.contentsOfDirectory(at: self.versionsDirectory, includingPropertiesForKeys: nil, options: [])
            let versionIds = contents.map({ Version.Identifier($0.lastPathComponent) })
            completionHandler(.success(versionIds))
        }
    }
    
    public func retrieveVersion(identifiedBy versionIdentifier: Version.Identifier, executingUponCompletion completionHandler: @escaping (ExchangeResult<Version>) -> Void) {
        coordinateFileAccess(.read, completionHandler: completionHandler) {
            let url = self.versionsDirectory.appendingPathComponent(versionIdentifier.identifierString)
            let data = try Data(contentsOf: url)
            if let version = try JSONDecoder().decode([String:Version].self, from: data)["version"] {
                completionHandler(.success(version))
            }
            else {
                completionHandler(.failure(Error.versionFileInvalid))
            }
        }
    }
    
    public func retrieveValueChanges(forVersionIdentifiedBy versionIdentifier: Version.Identifier, executingUponCompletion completionHandler: @escaping (ExchangeResult<[Value.Change]>) -> Void) {
        coordinateFileAccess(.read, completionHandler: completionHandler) {
            let url = self.changesDirectory.appendingPathComponent(versionIdentifier.identifierString)
            let data = try Data(contentsOf: url)
            let changes = try JSONDecoder().decode([Value.Change].self, from: data)
            completionHandler(.success(changes))
        }
    }
    
    public func send(_ version: Version, with valueChanges: [Value.Change], executingUponCompletion completionHandler: @escaping (ExchangeResult<Void>) -> Void) {
        coordinateFileAccess(.write, completionHandler: completionHandler) {
            let changesURL = self.changesDirectory.appendingPathComponent(version.identifier.identifierString)
            let changesData = try JSONEncoder().encode(valueChanges)
            try changesData.write(to: changesURL)
            
            let versionURL = self.versionsDirectory.appendingPathComponent(version.identifier.identifierString)
            let versionData = try JSONEncoder().encode(["version":version])
            try versionData.write(to: versionURL)
            
            completionHandler(.success(()))
        }
    }
    
    private enum FileAccess {
        case read, write
    }
    
    private func coordinateFileAccess<ResultType>(_ access: FileAccess, completionHandler: @escaping (ExchangeResult<ResultType>) -> Void, by block: @escaping () throws -> Void) {
        queue.addOperation {
            let coordinator = NSFileCoordinator(filePresenter: self)
            var error: NSError?
            
            let accessor: (URL)->Void = { url in
                do {
                    try block()
                } catch {
                    completionHandler(.failure(error))
                }
            }
            
            switch access {
            case .read:
                coordinator.coordinate(readingItemAt: self.rootDirectoryURL, options: [], error: &error, byAccessor: accessor)
            case .write:
                coordinator.coordinate(writingItemAt: self.rootDirectoryURL, options: [], error: &error, byAccessor: accessor)
            }
            
            if let error = error {
                completionHandler(.failure(error))
            }
        }
    }
    
}

extension FileSystemExchange: NSFilePresenter {
    
    public var presentedItemURL: URL? {
        return rootDirectoryURL
    }
    
    public var presentedItemOperationQueue: OperationQueue {
        return queue
    }
    
    public func presentedSubitemDidAppear(at url: URL) {
        type(of: self).cancelPreviousPerformRequests(withTarget: self, selector: #selector(notifyOfNewVersions), object: nil)
        perform(#selector(notifyOfNewVersions), with: nil, afterDelay: 1.0)
    }
    
    @objc private func notifyOfNewVersions() {
        OperationQueue.main.addOperation {
            self.client?.newVersionsAreAvailable(via: self)
        }
    }
}
