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
        case versionInvalid
        case changesInvalid
    }
    
    public let isPeerToPeer: Bool = true
    
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
        let message = RequestVersions(versionIds: versionIdentifiers)
        send(message, executingUponCompletion: completionHandler)
    }
    
    public func retrieveValueChanges(forVersionsIdentifiedBy versionIdentifiers: [Version.ID], executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.ID:[Value.Change]]>) {
        let message = RequestChanges(versionIds: versionIdentifiers)
        send(message, executingUponCompletion: completionHandler)
    }
    
    public func prepareToSend(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        completionHandler(.failure(ExchangeError.attemptToSendWithPeerToPeerExchange))
    }
    
    public func send(versionChanges: [VersionChanges], executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        // Because this is a peer-to-peer system, this should never be called. Peers only retrieve, they don't send.
        completionHandler(.failure(ExchangeError.attemptToSendWithPeerToPeerExchange))
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
            
            let replyData: Data
            switch request {
            case .versionIdentifiers:
                var message = try decoder.decode(RequestVersionIdentifiers.self, from: data)
                message.response = try localVersionIdentifiers()
                replyData = try encoder.encode(message)
            case .versions:
                var message = try decoder.decode(RequestVersions.self, from: data)
                message.response = try message.versionIds.map { id in
                    var version: Version?
                    try self.store.queryHistory { history in
                        if let v = history.version(identifiedBy: id) {
                            version = v
                        } else {
                            throw Error.versionInvalid
                        }
                    }
                    return version!
                }
                replyData = try encoder.encode(message)
            case .changes:
                var message = try decoder.decode(RequestChanges.self, from: data)
                message.response = try message.versionIds.reduce(into: [:]) { changesById, versionId in
                    changesById[versionId] = try self.store.valueChanges(madeInVersionIdentifiedBy: versionId)
                }
                replyData = try encoder.encode(message)
            }
            
            let dict: [String:Any] = [MessageKey.message.rawValue : replyData]
            replyHandler(dict)
        } catch {
            replyHandler([MessageKey.error.rawValue : RequestError.unexpectedError.rawValue])
        }
    }
    
}
