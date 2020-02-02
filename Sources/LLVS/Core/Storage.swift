//
//  Storage.swift
//  LLVS
//
//  Created by Drew McCormack on 14/05/2019.
//

import Foundation

public enum IndexType {
    case valuesByVersion // Main map for identifying which values are in each version
    case userDefined(label: String)
}

public protocol ZoneStorage {
    
    func makeValuesZone(in store: Store) -> Zone
    func makeIndexZone(for type: IndexType, in store: Store) -> Zone
    
}
