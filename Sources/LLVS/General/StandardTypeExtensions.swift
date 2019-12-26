//
//  File.swift
//  
//
//  Created by Drew McCormack on 26/12/2019.
//

import Foundation

extension Dictionary {
    
    init(withValues values: [Value], generatingUniqueKeysWith keyPath: KeyPath<Value, Key>) {
        self = .init(uniqueKeysWithValues: values.map({ ($0[keyPath: keyPath], $0) }))
    }
    
}
