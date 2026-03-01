//
//  SerialHistoryTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 04/02/2019.
//

import Testing
import Foundation

@testable import LLVS

@Suite class SerialHistoryTests {

    let fm = FileManager.default

    let valueId1 = Value.ID("ABCDEF")
    let valueId2 = Value.ID("ABCDGH")

    let store: Store
    let rootURL: URL
    let versions: [Version]

    init() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let s = try Store(rootDirectoryURL: rootURL)
        store = s

        var vers: [Version] = []
        vers.append(try s.makeVersion(basedOnPredecessor: vers.last?.id, storing: [.update(Value(id: Value.ID("ABCDEF"), data: "11".data(using: .utf8)!))]))
        vers.append(try s.makeVersion(basedOnPredecessor: vers.last?.id, storing: [.update(Value(id: Value.ID("ABCDGH"), data: "21".data(using: .utf8)!))]))
        vers.append(try s.makeVersion(basedOnPredecessor: vers.last?.id, storing: [.update(Value(id: Value.ID("ABCDEF"), data: "12".data(using: .utf8)!))]))
        vers.append(try s.makeVersion(basedOnPredecessor: vers.last?.id, storing: [.update(Value(id: Value.ID("ABCDGH"), data: "22".data(using: .utf8)!))]))
        vers.append(try s.makeVersion(basedOnPredecessor: vers.last?.id, storing: [.update(Value(id: Value.ID("ABCDEF"), data: "13".data(using: .utf8)!))]))
        vers.append(try s.makeVersion(basedOnPredecessor: vers.last?.id, storing: [.update(Value(id: Value.ID("ABCDGH"), data: "23".data(using: .utf8)!))]))
        versions = vers
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    @Test func valuesThroughoutHistory() throws {
        #expect(try store.value(id: valueId1, at: versions[1].id)!.data == "11".data(using: .utf8))
        #expect(try store.value(id: valueId2, at: versions[1].id)!.data == "21".data(using: .utf8))
        #expect(try store.value(id: valueId1, at: versions[2].id)!.data == "12".data(using: .utf8))
        #expect(try store.value(id: valueId2, at: versions[2].id)!.data == "21".data(using: .utf8))
        #expect(try store.value(id: valueId1, at: versions[3].id)!.data == "12".data(using: .utf8))
        #expect(try store.value(id: valueId2, at: versions[3].id)!.data == "22".data(using: .utf8))
        #expect(try store.value(id: valueId1, at: versions[4].id)!.data == "13".data(using: .utf8))
        #expect(try store.value(id: valueId2, at: versions[4].id)!.data == "22".data(using: .utf8))
        #expect(try store.value(id: valueId1, at: versions[5].id)!.data == "13".data(using: .utf8))
        #expect(try store.value(id: valueId2, at: versions[5].id)!.data == "23".data(using: .utf8))
    }
}
