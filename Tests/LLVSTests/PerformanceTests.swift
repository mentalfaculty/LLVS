//
//  PerformanceTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 14/02/2019.
//

import Testing
import Foundation
@testable import LLVS

@Suite class PerformanceTests {

    let fm = FileManager.default

    let valueId1 = Value.ID("ABCDEF")
    let valueId2 = Value.ID("ABCDGH")

    let store: Store
    let rootURL: URL

    init() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store = try Store(rootDirectoryURL: rootURL)
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

    /// A consumer keeping a derived view in step diffs on every save, so the cost of one diff
    /// must not grow with the length of history.
    ///
    /// It used to. Finding the greatest common ancestor builds the full ancestor set of one
    /// version, which measured 0.68 ms per diff at 100 versions and 17.19 ms at 3000 — linear,
    /// on the write path. `valueChanges(updatingFrom:to:)` now checks first whether the source
    /// is simply an ancestor of the target, which it is for two consecutive saves, and that
    /// took the same measurements to 0.13 ms and 0.36 ms.
    ///
    /// Residual growth remains, and it is not the ancestor walk: it is the size of the Map
    /// node holding the bucket these IDs land in, which is audit item 7. Measured over fifteen
    /// times the history, a shared ID prefix costs about 11x and spread IDs about 2.4x. This
    /// uses spread IDs, as `LLVSModel` now produces, and bounds what is left.
    ///
    /// It asserts the shape rather than a number, so it does not fail on a slower machine.
    @Test func diffCostDoesNotGrowWithHistoryLength() throws {
        func millisecondsPerDiff(afterBuildingUpTo depth: Int, from head: inout Version, previous: inout Version.ID) throws -> Double {
            while historyDepth < depth {
                let next = try store.makeVersion(basedOnPredecessor: head.id,
                    inserting: [Value(id: .init(UUID().uuidString), data: "x".data(using: .utf8)!)])
                previous = head.id
                head = next
                historyDepth += 1
            }
            let start = Date()
            let iterations = 20
            for _ in 0..<iterations { _ = try store.valueChanges(updatingFrom: previous, to: head.id) }
            return Date().timeIntervalSince(start) * 1000 / Double(iterations)
        }

        var head = try store.makeVersion(basedOnPredecessor: nil,
            inserting: [Value(id: .init("seed"), data: "s".data(using: .utf8)!)])
        var previous = head.id

        let near = try millisecondsPerDiff(afterBuildingUpTo: 100, from: &head, previous: &previous)
        let far = try millisecondsPerDiff(afterBuildingUpTo: 1500, from: &head, previous: &previous)

        // Fifteen times the history. The ancestor walk made this linear, about 15x; it now
        // measures about 2.4x from Map bucket growth alone. The bound catches a return to
        // linear cost while absorbing timing noise on a loaded machine.
        #expect(far < near * 6,
            "diff cost is growing with history: \(near) ms at depth 100, \(far) ms at depth 1500")
    }

    private var historyDepth = 0
}
