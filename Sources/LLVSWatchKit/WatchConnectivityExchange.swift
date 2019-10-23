//
//  File.swift
//  
//
//  Created by Drew McCormack on 08/10/2019.
//

import Foundation
import WatchConnectivity
import LLVS
import Combine

public class WatchConnectivityExchange: NSObject, Exchange {

    public enum Error: Swift.Error {
        case versionFileInvalid
        case changesFileInvalid
    }
    
    private let fileSystemExchange: FileSystemExchange
    private let session: WCSession
    
    public var store: Store { fileSystemExchange.store }
    public var rootDirectoryURL: URL { fileSystemExchange.rootDirectoryURL }

    @available(macOS 10.15, iOS 13, watchOS 6, *)
    public var newVersionsAvailable: AnyPublisher<Void, Never> {
        fileSystemExchange.newVersionsAvailable
    }
        
    public var restorationState: Data? {
        get { return nil }
        set {}
    }

    fileprivate let fileManager = FileManager()
    fileprivate let queue = OperationQueue()

    init(rootDirectoryURL: URL, store: Store, usesFileCoordination: Bool) {
        self.fileSystemExchange = .init(rootDirectoryURL: rootDirectoryURL, store: store, usesFileCoordination: usesFileCoordination)
        self.session = WCSession.default
        super.init()
        self.session.delegate = self
        self.session.activate()
    }
    
    public func prepareToRetrieve(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        fileSystemExchange.prepareToRetrieve(executingUponCompletion: completionHandler)
    }
    
    public func retrieveAllVersionIdentifiers(executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.Identifier]>) {
        fileSystemExchange.retrieveAllVersionIdentifiers(executingUponCompletion: completionHandler)
    }
    
    public func retrieveVersions(identifiedBy versionIdentifiers: [Version.Identifier], executingUponCompletion completionHandler: @escaping CompletionHandler<[Version]>) {
        fileSystemExchange.retrieveVersions(identifiedBy: versionIdentifiers, executingUponCompletion: completionHandler)
    }
    
    public func retrieveValueChanges(forVersionsIdentifiedBy versionIdentifiers: [Version.Identifier], executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.Identifier:[Value.Change]]>) {
        fileSystemExchange.retrieveValueChanges(forVersionsIdentifiedBy: versionIdentifiers, executingUponCompletion: completionHandler)
    }
    
    public func prepareToSend(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        fileSystemExchange.prepareToSend(executingUponCompletion: completionHandler)
    }
    
    public func send(versionChanges: [VersionChanges], executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        fileSystemExchange.send(versionChanges: versionChanges, executingUponCompletion: completionHandler)
    }
    
    private func localVersionFilenames() throws -> Set<String> {
        let files = try Set(fileManager.contentsOfDirectory(atPath: fileSystemExchange.versionsDirectory.path))
        return files
    }
    
    private func remoteVersionFilenames(executingUponCompletion completion: CompletionHandler<Set<String>>) throws {
//        session.sendMessage(<#T##message: [String : Any]##[String : Any]#>, replyHandler: <#T##(([String : Any]) -> Void)?##(([String : Any]) -> Void)?##([String : Any]) -> Void#>, errorHandler: <#T##((Error) -> Void)?##((Error) -> Void)?##(Error) -> Void#>)
    }
    
}


extension WatchConnectivityExchange: WCSessionDelegate {
    
    #if os(iOS)
    public func sessionDidBecomeInactive(_ session: WCSession) {
        
    }
    
    public func sessionDidDeactivate(_ session: WCSession) {
        session.activate() // Connect to different paired device
    }
    #endif
    
    public func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Swift.Error?) {
        
    }
    
    public func sessionReachabilityDidChange(_ session: WCSession) {
        
    }
    
    public func session(_ session: WCSession, didReceive file: WCSessionFile) {
        
    }
    
    public func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        
    }
    
    public func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void) {
        
    }
    
    public func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        
    }
    
}
