//
//  Entity.swift
//  LoCo
//
//  Created by Drew McCormack on 17/01/2019.
//  Copyright © 2019 The Mental Faculty B.V. All rights reserved.
//

import Foundation
import LLVS

fileprivate var encoder: JSONEncoder = .init()
fileprivate var decoder: JSONDecoder = .init()

class Entity<KeyType: StoreKey> {
    let store: Store
    let reference: Value.Reference
    
    init(store: Store, reference: Value.Reference) {
        self.store = store
        self.reference = reference
    }
    
    func load<ValueType: Codable>(_ storeKey: KeyType) throws -> ValueType? {
        let key = storeKey.key(forIdentifier: reference.identifier)
        let value = try store.value(.init(key), prevailingAt: reference.version)!
        return try decoder.decode(ValueType.self, from: value.data)
    }
}

protocol StoreKey {
    func key(forIdentifier identifier: Value.Identifier) -> String
}
