//
//  SQLitePerformanceTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 16/02/2022.
//

import Testing
import Foundation
@testable import LLVS
@testable import LLVSSQLite

@Suite class SQLitePerformanceTests {

    let fm = FileManager.default

    let valueId1 = Value.ID("ABCDEF")
    let valueId2 = Value.ID("ABCDGH")

    let store: Store
    let rootURL: URL

    init() throws {
        let storage = SQLiteStorage()
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store = try Store(rootDirectoryURL: rootURL, storage: storage)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func makeChanges(_ number: Int) -> [Value.Change]  {
        return (0..<number).map { _ in
            let data = try! JSONSerialization.data(withJSONObject: ["name":"Tom Jones", "age":18] as [String:Any], options: [])
            let value = Value(id: .init(UUID().uuidString), data: data)
            return .insert(value)
        }
    }

    let numberOfValues = 100

    @Test func storing() throws {
        let changes = makeChanges(numberOfValues)
        let _ = try store.makeVersion(basedOnPredecessor: nil, storing: changes)
    }

    @Test func loading() throws {
        let changes = makeChanges(numberOfValues)
        let valueIds: [Value.ID] = changes.compactMap { change in
            if case let .insert(value) = change { return value.id }
            fatalError()
        }
        let version = try store.makeVersion(basedOnPredecessor: nil, storing: changes)
        let _: [Any] = valueIds.map { valueId in
            let value = try! store.value(id: valueId, at: version.id)!
            return try! JSONSerialization.jsonObject(with: value.data, options: [])
        }
    }
}
