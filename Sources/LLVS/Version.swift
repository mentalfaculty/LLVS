//
//  Version.swift
//  llvs
//
//  Created by Drew McCormack on 31/10/2018.
//

import Foundation

public struct Version: Codable {
    
    public struct Identifier: StringIdentifiable, Codable {
        public var identifierString: String
        public init(identifierString: String = UUID().uuidString) {
            self.identifierString = identifierString
        }
    }
    
    public struct Predecessors: Codable {
        public var identifierOfFirst: Identifier
        public var identifierOfSecond: Identifier?
    }
    
    public var identifier: Identifier = .init()
    public var predecessors: Predecessors?
    
    public init(identifier: Identifier = .init(), predecessors: Predecessors? = nil) {
        
    }
}
