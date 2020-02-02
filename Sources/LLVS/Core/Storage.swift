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

public protocol Storage {
    
    func makeValuesZone(for store: Store) -> Zone
    func makeIndexZone(ofType type: IndexType, for store: Store) -> Zone
    
}
