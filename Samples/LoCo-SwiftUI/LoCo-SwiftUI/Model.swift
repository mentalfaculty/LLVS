//
//  Model.swift
//  LoCo-SwiftUI
//
//  Created by Drew McCormack on 09/07/2019.
//  Copyright © 2019 The Mental Faculty B.V. All rights reserved.
//

import Foundation
import SwiftUI
import LLVS

private let encoder = JSONEncoder()
private let decoder = JSONDecoder()

protocol Model: Codable, Identifiable, Equatable {
    
    var storeValueId: Value.Identifier { get }
    static var storeIdentifierTypeTag: String { get }
    static func storeValueId(for id: ID) -> Value.Identifier
    
    func encodeValue() throws -> Value
    static func decode(from value: Value) throws -> Self
    
}

extension Model {
    
    func encodeValue() throws -> Value {
        let data = try encoder.encode(self)
        return Value(identifier: type(of: self).storeValueId(for: id), version: nil, data: data)
    }
    
    static func decode(from value: Value) throws -> Self {
        return try decoder.decode(Self.self, from: value.data)
    }
    
    var storeValueId: Value.Identifier {
        type(of: self).storeValueId(for: id)
    }
    
    static func isValid(storeValueId: String) -> Bool {
        return storeValueId.hasSuffix(".\(storeIdentifierTypeTag)")
    }
    
}

extension Model where ID == UUID {
    
    static func storeValueId(for id: ID) -> Value.Identifier {
        .init("\(id.uuidString).\(storeIdentifierTypeTag)")
    }
    
}

extension Model {
    
    static func all(in storeCoordinator: StoreCoordinator, at verison: Version.Identifier? = nil) throws -> [Self] {
        return try storeCoordinator.valueReferences(at: verison)
            .filter { Self.isValid(storeValueId: $0.identifier.identifierString) }
            .map { try Self.decode(from: try storeCoordinator.store.value(at: $0)!) }
    }
    
}
