//
//  FileSystemExchange.swift
//  LLVS
//
//  Created by Drew McCormack on 25/02/2019.
//

import Foundation

public class FileSystemExchange: NSObject, Exchange, NSFilePresenter {

    public enum Error: Swift.Error {
        case versionFileInvalid
        case changesFileInvalid
    }
    
    public let store: Store
    
    public weak var client: ExchangeClient?
    
    public let rootDirectoryURL: URL
    public var versionsDirectory: URL { return rootDirectoryURL.appendingPathComponent("versions") }
    public var changesDirectory: URL { return rootDirectoryURL.appendingPathComponent("changes") }

    fileprivate let fileManager = FileManager()
    fileprivate let queue = OperationQueue()

    init(rootDirectoryURL: URL, store: Store) {
        self.rootDirectoryURL = rootDirectoryURL
        self.store = store
        super.init()
        try? fileManager.createDirectory(at: rootDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        try? fileManager.createDirectory(at: versionsDirectory, withIntermediateDirectories: true, attributes: nil)
        try? fileManager.createDirectory(at: changesDirectory, withIntermediateDirectories: true, attributes: nil)
        NSFileCoordinator.addFilePresenter(self)
    }
    
    deinit {
        NSFileCoordinator.removeFilePresenter(self)
    }
    
    public func prepareToRetrieve(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        completionHandler(.success(()))
    }
    
    public func retrieveAllVersionIdentifiers(executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.Identifier]>) {
        coordinateFileAccess(.read, completionHandler: completionHandler) {
            let contents = try self.fileManager.contentsOfDirectory(at: self.versionsDirectory, includingPropertiesForKeys: nil, options: [])
            let versionIds = contents.map({ Version.Identifier($0.lastPathComponent) })
            completionHandler(.success(versionIds))
        }
    }
    
    public func retrieveVersions(identifiedBy versionIdentifiers: [Version.Identifier], executingUponCompletion completionHandler: @escaping CompletionHandler<[Version]>) {
        coordinateFileAccess(.read, completionHandler: completionHandler) {
            let versions: [Version] = try versionIdentifiers.map { versionIdentifier in
                let url = self.versionsDirectory.appendingPathComponent(versionIdentifier.identifierString)
                let data = try Data(contentsOf: url)
                if let version = try JSONDecoder().decode([String:Version].self, from: data)["version"] {
                    return version
                } else {
                    throw Error.versionFileInvalid
                }
            }
            completionHandler(.success(versions))
        }
    }
    
    public func retrieveValueChanges(forVersionsIdentifiedBy versionIdentifiers: [Version.Identifier], executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.Identifier:[Value.Change]]>) {
        coordinateFileAccess(.read, completionHandler: completionHandler) {
            let result: [Version.Identifier:[Value.Change]] = try versionIdentifiers.reduce(into: [:]) { result, versionId in
                let url = self.changesDirectory.appendingPathComponent(versionId.identifierString)
                let data = try Data(contentsOf: url)
                let changes = try JSONDecoder().decode([Value.Change].self, from: data)
                result[versionId] = changes
            }
            completionHandler(.success(result))
        }
    }
    
    public func prepareToSend(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        completionHandler(.success(()))
    }
    
    public func send(_ version: Version, with valueChanges: [Value.Change], executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
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
    
    private func coordinateFileAccess<ResultType>(_ access: FileAccess, completionHandler: @escaping CompletionHandler<ResultType>, by block: @escaping () throws -> Void) {
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
    
    // MARK:- File Presenter
    
    public var presentedItemURL: URL? {
        return rootDirectoryURL
    }
    
    public var presentedItemOperationQueue: OperationQueue {
        return queue
    }
    
    private var notifyWorkItem: DispatchWorkItem?
    private let minimumDelayBeforeNotifyingOfNewVersions = 1.0
    
    public func presentedItemDidChange() {
        notifyWorkItem?.cancel()
        notifyWorkItem = DispatchWorkItem {
            self.client?.newVersionsAreAvailable(via: self)
        }
        DispatchQueue.main.asyncAfter(deadline: .now()+minimumDelayBeforeNotifyingOfNewVersions, execute: notifyWorkItem!)
    }
}
