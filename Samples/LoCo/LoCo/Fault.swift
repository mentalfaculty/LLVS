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
    init(_ valueIdentifier: Value.Identifier, prevailingAt version: Version.Identifier, loadingFrom store: Store) throws
}

final class Fault<ValueType: Faultable> {
    enum State {
        case fault
        case fetched(ValueType)
    }
    
    let store: Store
    let valueIdentifier: Value.Identifier
    let prevailingVersionIdentifier: Version.Identifier
    private(set) var state: State = .fault
    
    var value: ValueType {
        switch state {
        case .fault:
            let typedValue = try! ValueType(valueIdentifier, prevailingAt: prevailingVersionIdentifier, loadingFrom: store)
            state = .fetched(typedValue)
            return typedValue
        case let .fetched(value):
            return value
        }
    }
    
    init(_ valueIdentifier: Value.Identifier, prevailingAtVersion versionIdentifier: Version.Identifier, in store: Store) {
        self.valueIdentifier = valueIdentifier
        self.prevailingVersionIdentifier = versionIdentifier
        self.store = store
    }
}
