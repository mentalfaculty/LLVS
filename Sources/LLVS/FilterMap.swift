//
//  FilterMap.swift
//  LLVS
//
//  Created by Drew McCormack on 30/11/2018.
//

import Foundation

struct FilterMap {
    
    enum ReferenceSet: Codable {
        enum Error: Swift.Error {
            case noValidReferenceFound
        }
        
        enum Keys: CodingKey {
            case values
            case entries
        }
        
        case values([Value.Reference])
        case entries([Entry.Reference])
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            if let values = try? container.decode([Value.Reference].self, forKey: .values) {
                self = .values(values)
            } else if let entries = try? container.decode([Entry.Reference].self, forKey: .entries) {
                self = .entries(entries)
            } else {
                throw Error.noValidReferenceFound
            }
        }
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            switch self {
            case let .values(values):
                try container.encode(values, forKey: .values)
            case let .entries(entries):
                try container.encode(entries, forKey: .entries)
            }
        }
    }
    
    struct Entry: Codable {
        struct Reference: Codable {
            var identifier: Identifier
            var version: Version
        }
        
        public struct Identifier: StringIdentifiable, Codable {
            public var identifierString: String = UUID().uuidString
        }
        
        var identifier: Identifier
        var version: Version
        var references: ReferenceSet
    }
    
    let label: String
    
    init(label: String) {
        self.label = label
    }
    
}
