//
//  ValueChangesInVersionTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 13/03/2019.
//

import XCTest
import Foundation
@testable import LLVS

class ValueChangesInVersionTests: XCTestCase {

    let fm = FileManager.default
    
    var store: Store!
    var rootURL: URL!
    var originalVersion: Version!
    var branch1: Version!
    var branch2: Version!
    var originalValue: Value!
    var newValue1: Value!
    var newValue2: Value!
    
    var valueForMerge: Value!
    
    override func setUp() {
        super.setUp()
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store = try! Store(rootDirectoryURL: rootURL)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: rootURL)
        super.tearDown()
    }
    
    func testValuesConflictlessMerge() {
        let val1 = Value(identifier: .init("ABCDEF"), version: nil, data: "Bob".data(using: .utf8)!)
        var val2 = Value(identifier: .init("ABCD"), version: nil, data: "Tom".data(using: .utf8)!)
        let origin = try! store.addVersion(basedOn: nil, storing: [])
        let ver1 = try! store.addVersion(basedOnPredecessor: origin.identifier, storing: [.insert(val1)])
        let ver2 = try! store.addVersion(basedOnPredecessor: origin.identifier, storing: [.insert(val2)])
        val2.version = ver2.identifier
        let ver3 = try! store.addVersion(basedOn: .init(identifierOfFirst: ver1.identifier, identifierOfSecond: ver2.identifier), storing: [.preserve(val2.reference!)])
        let valueChanges = try! store.valueChanges(madeInVersionIdentifiedBy: ver3.identifier)
        let allPreserves = valueChanges.allSatisfy {
            if case .preserve = $0 {
                return true
            } else {
                return false
            }
        }
        XCTAssertTrue(allPreserves)
    }
    
    static var allTests = [
        ("testValuesConflictlessMerge", testValuesConflictlessMerge),
    ]
}



