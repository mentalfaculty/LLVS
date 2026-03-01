//
//  PrevailingValueTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 23/11/2018.
//

import Testing
import Foundation
@testable import LLVS

@Suite class PrevailingValueTests {

    let fm = FileManager.default
    let valueId = Value.ID("ABCDEF")

    let store: Store
    let rootURL: URL
    let valuesURL: URL
    let versions: [Version]

    init() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        valuesURL = rootURL.appendingPathComponent("values")
        let s = try Store(rootDirectoryURL: rootURL)
        store = s

        var vers: [Version] = []
        vers.append(try s.makeVersion(basedOnPredecessor: vers.last?.id, storing: []))
        vers.append(try s.makeVersion(basedOnPredecessor: vers.last?.id, storing: [.insert(Value(id: Value.ID("ABCDEF"), data: "1".data(using: .utf8)!))]))
        vers.append(try s.makeVersion(basedOnPredecessor: vers.last?.id, storing: []))
        vers.append(try s.makeVersion(basedOnPredecessor: vers.last?.id, storing: [.insert(Value(id: Value.ID("ABCDEF"), data: "2".data(using: .utf8)!))]))
        vers.append(try s.makeVersion(basedOnPredecessor: vers.last?.id, storing: [.insert(Value(id: Value.ID("ABCDEF"), data: "3".data(using: .utf8)!))]))
        vers.append(try s.makeVersion(basedOnPredecessor: vers.last?.id, storing: []))
        versions = vers
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    @Test func noSavedVersionAtPrevailingVersion() throws {
        #expect(try store.value(id: valueId, at: versions[0].id) == nil)
    }

    @Test func savedVersionMatchesPrevailingVersion() throws {
        let value = try store.value(id: valueId, at: versions[1].id)
        #expect(value!.data == "1".data(using: .utf8)!)
    }

    @Test func savedVersionPrecedesPrevailingVersion() throws {
        let value = try store.value(id: valueId, at: versions[5].id)
        #expect(value!.data == "3".data(using: .utf8)!)
    }
}
