//
//  PerformanceTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 14/02/2019.
//

import XCTest
@testable import LLVS

class PerformanceTests: XCTestCase {
    
    let fm = FileManager.default
    
    let valueIdentifier1 = Value.Identifier("ABCDEF")
    let valueIdentifier2 = Value.Identifier("ABCDGH")
    
    var store: Store!
    var rootURL: URL!
    var versions: [Version]!
    
    override func setUp() {
        super.setUp()
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store = try! Store(rootDirectoryURL: rootURL)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: rootURL)
        super.tearDown()
    }
    
    func makeChanges(_ number: Int) -> [Value.Change]  {
        return (0..<number).map { _ in
            let data = try! JSONSerialization.data(withJSONObject: ["name":"Tom Jones", "age":18], options: [])
            let value = Value(identifier: .init(UUID().uuidString), version: nil, data: data)
            return .insert(value)
        }
    }
    
    let numberOfValues = 100

    func testStoring() {
        let changes = makeChanges(numberOfValues)
        self.measure {
            let _ = try! store.addVersion(basedOnPredecessor: nil, storing: changes)
        }
    }
    
    func testLoading() {
        let changes = makeChanges(numberOfValues)
        let valueIds: [Value.Identifier] = changes.compactMap { change in
            if case let .insert(value) = change { return value.identifier }
            fatalError()
        }
        let version = try! store.addVersion(basedOnPredecessor: nil, storing: changes)
        self.measure {
            let _: [Any] = valueIds.map { valueId in
                let value = try! store.value(valueId, prevailingAt: version.identifier)!
                return try! JSONSerialization.jsonObject(with: value.data, options: [])
            }
        }
    }
    
    static var allTests = [
        ("testStoring", testStoring),
        ("testLoading", testLoading),
    ]

}
