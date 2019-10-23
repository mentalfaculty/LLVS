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

enum MessageType: MessageValue {
    case requestVersionFileList
    case requestVersionFiles(filenames: [String])
    case requestChangesFiles(filenames: [String])
    
    var messageDictionaryValue: Any {
        return ""
    }
}

enum MessageKey: String {
    case messageType
    case resultValue
}

protocol MessageValue {
    var messageDictionaryValue: Any { get }
}

protocol Message {
    associatedtype ResultType: MessageResult
    var messageDictionary: [MessageKey:MessageValue] { get }
}

extension Message {
    private var messageDictionaryForSession: [String:Any] {
        return [:]
    }
    
    func send(via sesssion: WCSession, executingUponCompletion completion: @escaping CompletionHandler<ResultType>) {
        sesssion.sendMessage(messageDictionaryForSession, replyHandler: { replyDict in
            guard let anyResult = replyDict[MessageKey.resultValue.rawValue], let result = try? ResultType(value: anyResult) else {
                completion(.failure(MessageError.unexpectedValueInResult))
                return
            }
            completion(.success(result))
        }) { error in
            completion(.failure(error))
        }
    }
}

protocol MessageResult {
    init(value: Any) throws
}

struct FilenameSet: MessageResult {
    var filenames: Set<String>
    
    init(value: Any) throws {
        guard let names = value as? Set<String> else {
            throw MessageError.unexpectedValueInResult
        }
        self.filenames = names
    }
}

struct RequestVersionFileList: Message {
    typealias ResultType = FilenameSet
    var messageDictionary: [MessageKey:MessageValue] {
        return [.messageType : MessageType.requestVersionFileList]
    }
}
