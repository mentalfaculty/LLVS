//
//  SharedStoreTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 16/03/2019.
//

import Testing
import Foundation
@testable import LLVS

@Suite class SharedStoreTests {

    let fm = FileManager.default

    let store1: Store
    let store2: Store
    let rootURL: URL

    init() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store1 = try Store(rootDirectoryURL: rootURL)
        store2 = try Store(rootDirectoryURL: rootURL)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func value(_ identifier: String, stringData: String) -> Value {
        return Value(id: .init(identifier), data: stringData.data(using: .utf8)!)
    }

    @Test func reloadHistoryInSecondStore() throws {
        let val = value("CDEFGH", stringData: "Origin")
        let ver = try store1.makeVersion(basedOnPredecessor: nil, storing: [.insert(val)])
        try store2.reloadHistory()
        let version = try store2.version(identifiedBy: ver.id)
        #expect(version != nil)
        let retrievedData = try store2.value(id: .init("CDEFGH"), storedAt: ver.id)!.data
        #expect(val.data == retrievedData)
    }

    @Test func twoWayTransfer() throws {
        let val1 = value("CDEFGH", stringData: "One")
        let ver1 = try store1.makeVersion(basedOnPredecessor: nil, storing: [.insert(val1)])

        try store2.reloadHistory()
        let val2 = value("CDEFGH", stringData: "Two")
        let ver2 = try store1.makeVersion(basedOnPredecessor: ver1.id, storing: [.update(val2)])

        try store1.reloadHistory()
        let version = try store1.version(identifiedBy: ver2.id)
        #expect(version != nil)
        let retrievedData = try store1.value(id: .init("CDEFGH"), storedAt: ver2.id)!.data
        #expect(val2.data == retrievedData)
    }
}
