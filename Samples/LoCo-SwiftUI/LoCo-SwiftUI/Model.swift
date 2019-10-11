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

/// Model types conform to this type to make it more convenient to store them.
/// The protocol takes care of converting ids into a form convenient for the LLVS
/// store, by appending the type string. This is used to identify data types when fetching.
/// Note that only structs that form the top of a encoded data blob should conform to
/// this. If a struct is just embedded in another struct, it can just conform to Codable.
protocol Model: Codable, Identifiable, Equatable {
    
    var storeValueId: Value.Identifier { get }
    static var storeIdentifierTypeTag: String { get }
    static func storeValueId(for id: ID) -> Value.Identifier
    
    func encodeValue() throws -> Value
    static func decode(from value: Value) throws -> Self
    
}

extension Model {
    
    /// Encode the model type as a Value for the LLVS store.
    func encodeValue() throws -> Value {
        let data = try encoder.encode(self)
        return Value(id: type(of: self).storeValueId(for: id), data: data)
    }
    
    /// Decode data from LLVS to form our model type.
    static func decode(from value: Value) throws -> Self {
        return try decoder.decode(Self.self, from: value.data)
    }
    
    /// The id used in the LLVS store. This is based on the model id, but also includes the type string.
    var storeValueId: Value.Identifier {
        type(of: self).storeValueId(for: id)
    }
    
    /// Tests if the store id is valid for the model type.
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
    
    /// Handy method for fetching all model values of a given type, at a given version (or the current version if nil is passed).
    /// This simply filters the values found based on the type string in the LLVS store identifier.
    static func all(in storeCoordinator: StoreCoordinator, at verison: Version.Identifier? = nil) throws -> [Self] {
        return try storeCoordinator.valueReferences(at: verison)
            .filter { Self.isValid(storeValueId: $0.valueId.stringValue) }
            .map { try Self.decode(from: try storeCoordinator.store.value(storedAt: $0)!) }
    }
    
}
