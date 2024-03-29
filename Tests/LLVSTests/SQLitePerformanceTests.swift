//
//  SQLitePerformanceTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 16/02/2022.
//

import XCTest
@testable import LLVS
@testable import LLVSSQLite

class SQLitePerformanceTests: XCTestCase {
    
    let fm = FileManager.default
    
    let valueId1 = Value.ID("ABCDEF")
    let valueId2 = Value.ID("ABCDGH")
    
    var store: Store!
    var rootURL: URL!
    var versions: [Version]!
    
    override func setUp() {
        super.setUp()
        let storage = SQLiteStorage()
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store = try! Store(rootDirectoryURL: rootURL, storage: storage)
    }
    
    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(at: rootURL)
        super.tearDown()
    }
    
    func makeChanges(_ number: Int) -> [Value.Change]  {
        return (0..<number).map { _ in
            let data = try! JSONSerialization.data(withJSONObject: ["name":"Tom Jones", "age":18] as [String:Any], options: [])
            let value = Value(id: .init(UUID().uuidString), data: data)
            return .insert(value)
        }
    }
    
    let numberOfValues = 100

    func testStoring() {
        let changes = makeChanges(numberOfValues)
        self.measure {
            let _ = try! store.makeVersion(basedOnPredecessor: nil, storing: changes)
        }
    }
    
    func testLoading() {
        let changes = makeChanges(numberOfValues)
        let valueIds: [Value.ID] = changes.compactMap { change in
            if case let .insert(value) = change { return value.id }
            fatalError()
        }
        let version = try! store.makeVersion(basedOnPredecessor: nil, storing: changes)
        self.measure {
            let _: [Any] = valueIds.map { valueId in
                let value = try! store.value(id: valueId, at: version.id)!
                return try! JSONSerialization.jsonObject(with: value.data, options: [])
            }
        }
    }
    
    static var allTests = [
        ("testStoring", testStoring),
        ("testLoading", testLoading),
    ]

}
