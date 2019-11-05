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
    var request: Request { .versions }
    var response: [Version]?
}

struct RequestChanges: Message {
    var id: UUID = .init()
    var request: Request { .changes }
    var response: [Value.Change]?
}

extension Message {
    func send(via sesssion: WCSession, executingUponCompletion completion: @escaping CompletionHandler<Self>) {
        let dict: [String:Any]
        do {
            dict = [MessageKey.message.rawValue : try JSONEncoder().encode(self), MessageKey.request.rawValue : request.rawValue]
        } catch {
            completion(.failure(error))
            return
        }
        
        sesssion.sendMessage(dict, replyHandler: { replyDict in
            guard let data = replyDict["message"] as? Data, let resultMessage = try? JSONDecoder().decode(type(of: self), from: data) else {
                completion(.failure(MessageError.unexpectedValueInResult))
                return
            }
            completion(.success(resultMessage))
        }) { error in
            completion(.failure(error))
        }
    }
}
