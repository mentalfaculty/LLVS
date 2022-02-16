//
//  Storage.swift
//  LLVS
//
//  Created by Drew McCormack on 14/05/2019.
//

import Foundation

public enum MapType {
    case valuesByVersion // Main map for identifying which values are in each version
    case userDefined(label: String)
}

public protocol Storage {
    
    func makeValuesZone(in store: Store) throws -> Zone
    func makeMapZone(for type: MapType, in store: Store) throws -> Zone
    
}
