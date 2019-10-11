//
//  SharedStoreTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 16/03/2019.
//

import XCTest
import Foundation
@testable import LLVS

class SharedStoreTests: XCTestCase {

    let fm = FileManager.default
    
    var store1, store2: Store!
    var rootURL: URL!
    
    override func setUp() {
        super.setUp()
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store1 = try! Store(rootDirectoryURL: rootURL)
        store2 = try! Store(rootDirectoryURL: rootURL)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: rootURL)
        super.tearDown()
    }
    
    private func value(_ identifier: String, stringData: String) -> Value {
        return Value(id: .init(identifier), data: stringData.data(using: .utf8)!)
    }
    
    func testReloadHistoryInSecondStore() {
        let val = value("CDEFGH", stringData: "Origin")
        let ver = try! store1.makeVersion(basedOnPredecessor: nil, storing: [.insert(val)])
        try! store2.reloadHistory()
        XCTAssertNotNil(try! store2.version(identifiedBy: ver.id))
        XCTAssertEqual(val.data, try! store2.value(id: .init("CDEFGH"), storedAt: ver.id)!.data)
    }
    
    func testTwoWayTransfer() {
        let val1 = value("CDEFGH", stringData: "One")
        let ver1 = try! store1.makeVersion(basedOnPredecessor: nil, storing: [.insert(val1)])
        
        try! store2.reloadHistory()
        let val2 = value("CDEFGH", stringData: "Two")
        let ver2 = try! store1.makeVersion(basedOnPredecessor: ver1.id, storing: [.update(val2)])
        
        try! store1.reloadHistory()
        XCTAssertNotNil(try! store1.version(identifiedBy: ver2.id))
        XCTAssertEqual(val2.data, try! store1.value(id: .init("CDEFGH"), storedAt: ver2.id)!.data)
    }

    static var allTests = [
        ("testReloadHistoryInSecondStore", testReloadHistoryInSecondStore),
    ]
}
