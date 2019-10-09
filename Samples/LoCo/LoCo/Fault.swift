//
//  Fault.swift
//  LoCo
//
//  Created by Drew McCormack on 21/01/2019.
//  Copyright © 2019 The Mental Faculty B.V. All rights reserved.
//

import Foundation
import LLVS

protocol Faultable {
    init(_ valueId: Value.Identifier, at version: Version.Identifier, loadingFrom store: Store) throws
}

final class Fault<ValueType: Faultable> {
    enum State {
        case fault
        case fetched(ValueType)
    }
    
    let store: Store
    let valueId: Value.Identifier
    let prevailingVersionIdentifier: Version.Identifier
    private(set) var state: State = .fault
    
    var value: ValueType {
        switch state {
        case .fault:
            let typedValue = try! ValueType(valueId, at: prevailingVersionIdentifier, loadingFrom: store)
            state = .fetched(typedValue)
            return typedValue
        case let .fetched(value):
            return value
        }
    }
    
    init(_ valueId: Value.Identifier, atVersion versionId: Version.Identifier, in store: Store) {
        self.valueId = valueId
        self.prevailingVersionIdentifier = versionId
        self.store = store
    }
}
