//
//  StoreCoordinator+Model.swift
//  LLVS
//
//  Created by Drew McCormack on 01/03/2026.
//

import Foundation
import LLVS

public extension StoreCoordinator {

    /// Save a model value, inserting or updating as appropriate.
    func save<T: StorableModel>(_ model: T, instanceIdentifier: String, in branch: Branch? = nil) throws {
        let valueId = modelValueID(typeIdentifier: T.modelTypeIdentifier, instanceIdentifier: instanceIdentifier)
        let data = try JSONEncoder().encode(model)
        let existing = try value(id: valueId, on: branch)
        if existing != nil {
            try save(updating: [Value(id: valueId, data: data)], in: branch)
        } else {
            try save(inserting: [Value(id: valueId, data: data)], in: branch)
        }
    }

    /// Fetch a single model value by its instance identifier.
    func fetchModel<T: StorableModel>(_ type: T.Type, instanceIdentifier: String, on branch: Branch? = nil) throws -> T? {
        let valueId = modelValueID(typeIdentifier: T.modelTypeIdentifier, instanceIdentifier: instanceIdentifier)
        guard let value = try value(id: valueId, on: branch) else { return nil }
        return try JSONDecoder().decode(T.self, from: value.data)
    }

    /// Remove a model value.
    func removeModel<T: StorableModel>(_ type: T.Type, instanceIdentifier: String, in branch: Branch? = nil) throws {
        let valueId = modelValueID(typeIdentifier: T.modelTypeIdentifier, instanceIdentifier: instanceIdentifier)
        try save(removing: [valueId], in: branch)
    }

    /// Fetch all model values of a given type by scanning value references for matching prefixes.
    func fetchAllModels<T: StorableModel>(_ type: T.Type, at version: Version.ID? = nil) throws -> [T] {
        let prefix = T.modelTypeIdentifier + "/"
        let refs = try valueReferences(at: version)
        let decoder = JSONDecoder()
        return try refs.compactMap { ref in
            guard ref.valueId.rawValue.hasPrefix(prefix) else { return nil }
            guard let value = try store.value(storedAt: ref) else { return nil }
            return try decoder.decode(T.self, from: value.data)
        }
    }
}
