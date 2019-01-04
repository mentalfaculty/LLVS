//
//  Version.swift
//  llvs
//
//  Created by Drew McCormack on 31/10/2018.
//

import Foundation

public struct Version: Codable, Hashable {
    
    public var identifier: Identifier = .init()
    public var predecessors: Predecessors?
    public var successors: Successors = .init()
    public var timestamp: TimeInterval
    
    public init(identifier: Identifier = .init(), predecessors: Predecessors? = nil) {
        self.identifier = identifier
        self.predecessors = predecessors
        self.timestamp = Date().timeIntervalSinceReferenceDate
    }
    
}


extension Version {
    
    public struct Identifier: StringIdentifiable, Codable, Hashable {
        public var identifierString: String
        public init(_ identifierString: String = UUID().uuidString) {
            self.identifierString = identifierString
        }
    }
    
    public struct Predecessors: Codable, Hashable {
        public internal(set) var identifierOfFirst: Identifier
        public internal(set) var identifierOfSecond: Identifier?
        public var identifiers: [Identifier] {
            var result = [identifierOfFirst]
            if let second = identifierOfSecond { result.append(second) }
            return result
        }
        
        internal init(identifierOfFirst: Identifier, identifierOfSecond: Identifier?) {
            self.identifierOfFirst = identifierOfFirst
            self.identifierOfSecond = identifierOfSecond
        }
    }
    
    public struct Successors: Codable, Hashable {
        public internal(set) var identifiers: Set<Identifier>
        internal init(identifiers: Set<Identifier> = []) {
            self.identifiers = identifiers
        }
    }

}


extension Collection where Element == Version {
    
    var identifiers: [Version.Identifier] {
        return map { $0.identifier }
    }
    
}
