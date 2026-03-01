//
//  MostRecentChangeFavoringArbiterTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 10/03/2019.
//

import Testing
import Foundation
@testable import LLVS

@Suite class MostRecentChangeMergeArbiterTests {

    let fm = FileManager.default

    let store: Store
    let rootURL: URL
    let origin: Version

    let recentChangeArbiter: MostRecentChangeFavoringArbiter

    init() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store = try Store(rootDirectoryURL: rootURL)
        let originVal = Value(id: .init("CDEFGH"), data: "Origin".data(using: .utf8)!)
        origin = try store.makeVersion(basedOnPredecessor: nil, storing: [.insert(originVal)])
        recentChangeArbiter = MostRecentChangeFavoringArbiter()
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func value(_ identifier: String, stringData: String) -> Value {
        return Value(id: .init(identifier), data: stringData.data(using: .utf8)!)
    }

    @Test func remove() throws {
        let ver1 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [.remove(.init("CDEFGH"))])
        let ver2 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [])
        let mergeVersion = try store.mergeRelated(version: ver1.id, with: ver2.id, resolvingWith: recentChangeArbiter)
        let f = try store.value(id: .init("CDEFGH"), at: mergeVersion.id)
        #expect(f == nil)
    }

    @Test func twiceRemove() throws {
        let ver1 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [.remove(.init("CDEFGH"))])
        let ver2 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [.remove(.init("CDEFGH"))])
        let ver3 = try store.makeVersion(basedOnPredecessor: ver2.id, storing: [])
        let mergeVersion = try store.mergeRelated(version: ver1.id, with: ver3.id, resolvingWith: recentChangeArbiter)
        let f = try store.value(id: .init("CDEFGH"), at: mergeVersion.id)
        #expect(f == nil)
    }

    @Test func insert() throws {
        do {
            let val1 = value("ABCDEF", stringData: "Bob")
            let ver1 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [.insert(val1)])
            let ver2 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [])
            let ver3 = try store.makeVersion(basedOnPredecessor: ver1.id, storing: [])
            let mergeVersion = try store.mergeRelated(version: ver3.id, with: ver2.id, resolvingWith: recentChangeArbiter)
            let f = try store.value(id: .init("ABCDEF"), at: mergeVersion.id)!
            #expect(f.data == "Bob".data(using: .utf8))
            #expect(f.storedVersionId == ver1.id)
        }

        do {
            let val1 = value("ABCDEF", stringData: "Bob")
            let ver1 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [])
            let ver2 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [.insert(val1)])
            let mergeVersion = try store.mergeRelated(version: ver1.id, with: ver2.id, resolvingWith: recentChangeArbiter)
            let f = try store.value(id: .init("ABCDEF"), at: mergeVersion.id)!
            #expect(f.data == "Bob".data(using: .utf8))
            #expect(f.storedVersionId == ver2.id)
        }
    }

    @Test func twiceInserted() throws {
        let val1 = value("ABCDEF", stringData: "Bob")
        let val2 = value("ABCDEF", stringData: "Tom")
        let ver1 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [.insert(val1)])
        let ver2 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [.insert(val2)])
        let ver3 = try store.makeVersion(basedOnPredecessor: ver1.id, storing: [])
        let mergeVersion = try store.mergeRelated(version: ver3.id, with: ver2.id, resolvingWith: recentChangeArbiter)
        let f = try store.value(id: .init("ABCDEF"), at: mergeVersion.id)!
        #expect(f.data == "Tom".data(using: .utf8))
        #expect(f.storedVersionId == ver2.id)
    }

    @Test func twiceInsertedAndUpdated() throws {
        let val1 = value("ABCDEF", stringData: "Bob")
        let val2 = value("ABCDEF", stringData: "Tom")
        let val3 = value("ABCDEF", stringData: "Dave")
        let ver1 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [.insert(val1)])
        let ver2 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [.insert(val2)])
        let ver3 = try store.makeVersion(basedOnPredecessor: ver1.id, storing: [.update(val3)])
        let mergeVersion = try store.mergeRelated(version: ver3.id, with: ver2.id, resolvingWith: recentChangeArbiter)
        let f = try store.value(id: .init("ABCDEF"), at: mergeVersion.id)!
        #expect(f.data == "Dave".data(using: .utf8))
        #expect(f.storedVersionId == ver3.id)
    }

    @Test func updated() throws {
        let val1 = value("CDEFGH", stringData: "Bob")
        let ver1 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [.update(val1)])
        let ver2 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [])
        let mergeVersion = try store.mergeRelated(version: ver1.id, with: ver2.id, resolvingWith: recentChangeArbiter)
        let f = try store.value(id: .init("CDEFGH"), at: mergeVersion.id)!
        #expect(f.data == "Bob".data(using: .utf8))
        #expect(f.storedVersionId == ver1.id)
    }

    @Test func twiceUpdated() throws {
        let val1 = value("CDEFGH", stringData: "Bob")
        let val2 = value("CDEFGH", stringData: "Tom")
        let val3 = value("CDEFGH", stringData: "Dave")
        let ver1 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [.update(val1)])
        let ver2 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [.update(val2)])
        let ver3 = try store.makeVersion(basedOnPredecessor: ver1.id, storing: [.update(val3)])
        let mergeVersion = try store.mergeRelated(version: ver3.id, with: ver2.id, resolvingWith: recentChangeArbiter)
        let f = try store.value(id: .init("CDEFGH"), at: mergeVersion.id)!
        #expect(f.data == "Dave".data(using: .utf8))
        #expect(f.storedVersionId == ver3.id)
    }

    @Test func removedAndUpdated() throws {
        do {
            let val1 = value("CDEFGH", stringData: "Bob")
            let ver1 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [.update(val1)])
            let ver2 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [.remove(.init("CDEFGH"))])
            let mergeVersion = try store.mergeRelated(version: ver1.id, with: ver2.id, resolvingWith: recentChangeArbiter)
            let f = try store.value(id: .init("CDEFGH"), at: mergeVersion.id)!
            #expect(f.data == "Bob".data(using: .utf8))
            #expect(f.storedVersionId == ver1.id)
        }
        do {
            let val1 = value("CDEFGH", stringData: "Bob")
            let ver1 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [.remove(.init("CDEFGH"))])
            let ver2 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [.update(val1)])
            let mergeVersion = try store.mergeRelated(version: ver1.id, with: ver2.id, resolvingWith: recentChangeArbiter)
            let f = try store.value(id: .init("CDEFGH"), at: mergeVersion.id)!
            #expect(f.data == "Bob".data(using: .utf8))
            #expect(f.storedVersionId == ver2.id)
        }
    }
}
