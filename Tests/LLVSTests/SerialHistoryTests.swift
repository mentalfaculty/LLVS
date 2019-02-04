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
    let valueIdentifier1 = Value.Identifier("ABCDEF")
    let valueIdentifier2 = Value.Identifier("CDEFGH")

    var store: Store!
    var rootURL: URL!
    var versions: [Version]!
    
    override func setUp() {
        func addVersion(withString stringValue: String, valueIdentifier: Value.Identifier) {
            let values: [Value] = [Value(identifier: valueIdentifier, version: nil, data: stringValue.data(using: .utf8)!)]
            let changes: [Value.Change] = values.map { .update($0) }
            let version = try! store.addVersion(basedOnPredecessor: versions!.last?.identifier, storing: changes)
            versions.append(version)
        }
        
        super.setUp()
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store = try! Store(rootDirectoryURL: rootURL)
        
        versions = []
        addVersion(withString: "11", valueIdentifier: valueIdentifier1)
        addVersion(withString: "21", valueIdentifier: valueIdentifier2)
        addVersion(withString: "12", valueIdentifier: valueIdentifier1)
        addVersion(withString: "22", valueIdentifier: valueIdentifier2)
        addVersion(withString: "13", valueIdentifier: valueIdentifier1)
        addVersion(withString: "23", valueIdentifier: valueIdentifier2)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: rootURL)
        super.tearDown()
    }
    
    func testValuesThroughoutHistory() {
        XCTAssertEqual(try store.value(valueIdentifier1, prevailingAt: versions[0].identifier)!.data, "11".data(using: .utf8))
        XCTAssertNil(try store.value(valueIdentifier2, prevailingAt: versions[0].identifier))
        XCTAssertEqual(try store.value(valueIdentifier1, prevailingAt: versions[1].identifier)!.data, "11".data(using: .utf8))
        XCTAssertEqual(try store.value(valueIdentifier2, prevailingAt: versions[1].identifier)!.data, "21".data(using: .utf8))
        XCTAssertEqual(try store.value(valueIdentifier1, prevailingAt: versions[2].identifier)!.data, "12".data(using: .utf8))
        XCTAssertEqual(try store.value(valueIdentifier2, prevailingAt: versions[2].identifier)!.data, "21".data(using: .utf8))
        XCTAssertEqual(try store.value(valueIdentifier1, prevailingAt: versions[3].identifier)!.data, "12".data(using: .utf8))
        XCTAssertEqual(try store.value(valueIdentifier2, prevailingAt: versions[3].identifier)!.data, "22".data(using: .utf8))
        XCTAssertEqual(try store.value(valueIdentifier1, prevailingAt: versions[4].identifier)!.data, "13".data(using: .utf8))
        XCTAssertEqual(try store.value(valueIdentifier2, prevailingAt: versions[4].identifier)!.data, "22".data(using: .utf8))
        XCTAssertEqual(try store.value(valueIdentifier1, prevailingAt: versions[5].identifier)!.data, "13".data(using: .utf8))
        XCTAssertEqual(try store.value(valueIdentifier2, prevailingAt: versions[5].identifier)!.data, "23".data(using: .utf8))
    }

    static var allTests = [
        ("testValuesThroughoutHistory", testValuesThroughoutHistory),
    ]
}
