//
//  SerialHistoryTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 04/02/2019.
//

import XCTest

@testable import LLVS

class SerialHistoryTests: XCTestCase {

    let fm = FileManager.default
    
    let valueId1 = Value.ID("ABCDEF")
    let valueId2 = Value.ID("ABCDGH")

    var store: Store!
    var rootURL: URL!
    var versions: [Version]!
    
    override func setUp() {
        func addVersion(withString stringValue: String, valueId: Value.ID) {
            let values: [Value] = [Value(id: valueId, data: stringValue.data(using: .utf8)!)]
            let changes: [Value.Change] = values.map { .update($0) }
            let version = try! store.makeVersion(basedOnPredecessor: versions!.last?.id, storing: changes)
            versions.append(version)
        }
        
        super.setUp()
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store = try! Store(rootDirectoryURL: rootURL)
        
        versions = []
        addVersion(withString: "11", valueId: valueId1)
        addVersion(withString: "21", valueId: valueId2)
        addVersion(withString: "12", valueId: valueId1)
        addVersion(withString: "22", valueId: valueId2)
        addVersion(withString: "13", valueId: valueId1)
        addVersion(withString: "23", valueId: valueId2)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: rootURL)
        super.tearDown()
    }
    
    func testValuesThroughoutHistory() {
//        XCTAssertEqual(try store.value(valueId1, at: versions[0].id)!.data, "11".data(using: .utf8))
//        XCTAssertNil(try store.value(valueId2, at: versions[0].id))
        XCTAssertEqual(try store.value(id: valueId1, at: versions[1].id)!.data, "11".data(using: .utf8))
        XCTAssertEqual(try store.value(id: valueId2, at: versions[1].id)!.data, "21".data(using: .utf8))
        XCTAssertEqual(try store.value(id: valueId1, at: versions[2].id)!.data, "12".data(using: .utf8))
        XCTAssertEqual(try store.value(id: valueId2, at: versions[2].id)!.data, "21".data(using: .utf8))
        XCTAssertEqual(try store.value(id: valueId1, at: versions[3].id)!.data, "12".data(using: .utf8))
        XCTAssertEqual(try store.value(id: valueId2, at: versions[3].id)!.data, "22".data(using: .utf8))
        XCTAssertEqual(try store.value(id: valueId1, at: versions[4].id)!.data, "13".data(using: .utf8))
        XCTAssertEqual(try store.value(id: valueId2, at: versions[4].id)!.data, "22".data(using: .utf8))
        XCTAssertEqual(try store.value(id: valueId1, at: versions[5].id)!.data, "13".data(using: .utf8))
        XCTAssertEqual(try store.value(id: valueId2, at: versions[5].id)!.data, "23".data(using: .utf8))
    }

    static var allTests = [
        ("testValuesThroughoutHistory", testValuesThroughoutHistory),
    ]
}
