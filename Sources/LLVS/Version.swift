//
//  Version.swift
//  llvs
//
//  Created by Drew McCormack on 31/10/2018.
//

import Foundation

public struct Version: Codable, Hashable {
    
    public struct Identifier: StringIdentifiable, Codable, Hashable {
        public var identifierString: String
        public init(identifierString: String = UUID().uuidString) {
            self.identifierString = identifierString
        }
    }
    
    public struct Predecessors: Codable, Hashable {
        public var identifierOfFirst: Identifier
        public var identifierOfSecond: Identifier?
    }
    
    public var identifier: Identifier = .init()
    public var predecessors: Predecessors?
    
    public init(identifier: Identifier = .init(), predecessors: Predecessors? = nil) {
        self.identifier = identifier
        self.predecessors = predecessors
    }
    
}
