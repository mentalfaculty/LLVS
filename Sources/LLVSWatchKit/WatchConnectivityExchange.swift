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
    
    private let session: WCSession
    
    public let store: Store
    
    private let minimumDelayBeforeNotifyingOfNewVersions = 1.0
    
    @available(macOS 10.15, iOS 13, watchOS 6, *)
    private lazy var newVersionsSubject: PassthroughSubject<Void, Never> = .init()

    @available(macOS 10.15, iOS 13, watchOS 6, *)
    public var newVersionsAvailable: AnyPublisher<Void, Never> {
        newVersionsSubject
            .debounce(for: .seconds(minimumDelayBeforeNotifyingOfNewVersions), scheduler: RunLoop.main)
            .eraseToAnyPublisher()
    }
        
    public var restorationState: Data? {
        get { return nil }
        set {}
    }

    fileprivate let queue = OperationQueue()

    init(store: Store) {
        self.session = WCSession.default
        self.store = store
        super.init()
        self.session.delegate = self
        self.session.activate()
    }
    
    public func prepareToRetrieve(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        completionHandler(.success(()))
    }
    
    public func retrieveAllVersionIdentifiers(executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.ID]>) {
        let message = RequestVersionIdentifiers()
        send(message, executingUponCompletion: completionHandler)
    }
    
    public func retrieveVersions(identifiedBy versionIdentifiers: [Version.ID], executingUponCompletion completionHandler: @escaping CompletionHandler<[Version]>) {
//        fileSystemExchange.retrieveVersions(identifiedBy: versionIdentifiers, executingUponCompletion: completionHandler)
    }
    
    public func retrieveValueChanges(forVersionsIdentifiedBy versionIdentifiers: [Version.ID], executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.ID:[Value.Change]]>) {
//        fileSystemExchange.retrieveValueChanges(forVersionsIdentifiedBy: versionIdentifiers, executingUponCompletion: completionHandler)
    }
    
    public func prepareToSend(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        completionHandler(.success(()))
    }
    
    public func send(versionChanges: [VersionChanges], executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
//        fileSystemExchange.send(versionChanges: versionChanges, executingUponCompletion: completionHandler)
    }
    
    fileprivate func localVersionIdentifiers() throws -> [Version.ID] {
        var ids: [Version.ID] = []
        store.queryHistory { ids = $0.allVersionIdentifiers }
        return ids
    }
    
    fileprivate func send<T:Message>(_ message: T, executingUponCompletion completion: @escaping CompletionHandler<T.ResponseType>) {
        message.send(via: session) { result in
            switch result {
            case let .failure(error):
                completion(.failure(error))
            case let .success(resultMessage):
                completion(.success(resultMessage.response!))
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
            case .versionIdentifiers:
                var message = try decoder.decode(RequestVersionIdentifiers.self, from: data)
                message.response = try localVersionIdentifiers()
                let dict: [String:Any] = [MessageKey.message.rawValue : try encoder.encode(message)]
                replyHandler(dict)
            case .versions:
                break
            case .changes:
                break
            }
        } catch {
            replyHandler([MessageKey.error.rawValue : RequestError.unexpectedError.rawValue])
            return
        }
    }
    
}
