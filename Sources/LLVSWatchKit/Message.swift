//
//  File.swift
//  
//
//  Created by Drew McCormack on 23/10/2019.
//

import Foundation
import WatchConnectivity
import LLVS

enum MessageError: Swift.Error {
    case unexpectedValueInResult
    case counterpartDeviceUnreachable
}

enum RequestError: Int {
    case unexpectedError
    case invalidRequestInMessage
    case noDataInMessage
}

enum Request: String, Codable {
    case versionIdentifiers
    case versions
    case changes
}

enum MessageKey: String {
    case message, request, error
}

protocol Message: Codable, Identifiable {
    associatedtype ResponseType: Codable
    var request: Request { get }
    var response: ResponseType? { get set }
}

struct RequestVersionIdentifiers: Message {
    var id: UUID = .init()
    var request: Request { .versionIdentifiers }
    var response: [Version.ID]?
}

struct RequestVersions: Message {
    var id: UUID = .init()
    var versionIds: [Version.ID]
    var request: Request { .versions }
    var response: [Version]?
}

struct RequestChanges: Message {
    var id: UUID = .init()
    var versionIds: [Version.ID]
    var request: Request { .changes }
    var response: [Version.ID:[Value.Change]]?
}

extension Message {
    func send(via session: WCSession, executingUponCompletion completionHandler: @escaping CompletionHandler<Self>) {
        guard session.isReachable else {
            completionHandler(.failure(MessageError.counterpartDeviceUnreachable))
            return
        }
        
        let dict: [String:Any]
        do {
            dict = [MessageKey.message.rawValue : try JSONEncoder().encode(self), MessageKey.request.rawValue : request.rawValue]
        } catch {
            completionHandler(.failure(error))
            return
        }
        
        session.sendMessage(dict, replyHandler: { replyDict in
            guard let data = replyDict["message"] as? Data, let resultMessage = try? JSONDecoder().decode(type(of: self), from: data) else {
                completionHandler(.failure(MessageError.unexpectedValueInResult))
                return
            }
            completionHandler(.success(resultMessage))
        }) { error in
            completionHandler(.failure(error))
        }
    }
}
