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
    
    fileprivate func localVersionFilenames() throws -> Set<String> {
        let files = try Set(fileManager.contentsOfDirectory(atPath: fileSystemExchange.versionsDirectory.path))
        return files
    }
    
    fileprivate func remoteVersionFilenames(executingUponCompletion completion: @escaping CompletionHandler<Set<String>>) throws {
        let message = RequestVersionFileList()
        message.send(via: session) { result in
            switch result {
            case let .failure(error):
                completion(.failure(error))
            case let .success(resultMessage):
                completion(.success(resultMessage.resultFilenames ?? []))
            }
        }
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
    
//    public func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
//
//    }
    
    public func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void) {
        guard let string = message[MessageKey.request.rawValue] as? String, let request = Request(rawValue: string) else {
            replyHandler([MessageKey.error.rawValue : RequestError.invalidRequestInMessage.rawValue])
            return
        }
        guard let data = message[MessageKey.message.rawValue] as? Data else {
            replyHandler([MessageKey.error.rawValue : RequestError.noDataInMessage.rawValue])
            return
        }
        
        do {
            let decoder = JSONDecoder()
            let encoder = JSONEncoder()
            switch request {
            case .versionFileList:
                var message = try decoder.decode(RequestVersionFileList.self, from: data)
                message.resultFilenames = try localVersionFilenames()
                let dict: [String:Any] = [MessageKey.message.rawValue : try encoder.encode(message)]
                replyHandler(dict)
            case .versionFiles:
                break
            case .changesFiles:
                break
            }
        } catch {
            replyHandler([MessageKey.error.rawValue : RequestError.unexpectedError.rawValue])
            return
        }
    }
    
}
