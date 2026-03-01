//
//  MergeArbiterTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 09/03/2019.
//

import Testing
import Foundation
@testable import LLVS

@Suite class MostRecentBranchMergeArbiterTests {

    let fm = FileManager.default

    let store: Store
    let rootURL: URL
    let origin: Version

    let recentBranchArbiter: MostRecentBranchFavoringArbiter

    init() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store = try Store(rootDirectoryURL: rootURL)
        let originVal = Value(id: .init("CDEFGH"), data: "Origin".data(using: .utf8)!)
        origin = try store.makeVersion(basedOnPredecessor: nil, storing: [.insert(originVal)])
        recentBranchArbiter = MostRecentBranchFavoringArbiter()
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
        let mergeVersion = try store.mergeRelated(version: ver1.id, with: ver2.id, resolvingWith: recentBranchArbiter)
        let f = try store.value(id: .init("CDEFGH"), at: mergeVersion.id)
        #expect(f == nil)
    }

    @Test func twiceRemove() throws {
        let ver1 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [.remove(.init("CDEFGH"))])
        let ver2 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [.remove(.init("CDEFGH"))])
        let mergeVersion = try store.mergeRelated(version: ver1.id, with: ver2.id, resolvingWith: recentBranchArbiter)
        let f = try store.value(id: .init("CDEFGH"), at: mergeVersion.id)
        #expect(f == nil)
    }

    @Test func insert() throws {
        do {
            let val1 = value("ABCDEF", stringData: "Bob")
            let ver1 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [.insert(val1)])
            let ver2 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [])
            let mergeVersion = try store.mergeRelated(version: ver1.id, with: ver2.id, resolvingWith: recentBranchArbiter)
            let f = try store.value(id: .init("ABCDEF"), at: mergeVersion.id)!
            #expect(f.data == "Bob".data(using: .utf8))
            #expect(f.storedVersionId == ver1.id)
        }

        do {
            let val1 = value("ABCDEF", stringData: "Bob")
            let ver1 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [])
            let ver2 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [.insert(val1)])
            let mergeVersion = try store.mergeRelated(version: ver1.id, with: ver2.id, resolvingWith: recentBranchArbiter)
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
        let mergeVersion = try store.mergeRelated(version: ver1.id, with: ver2.id, resolvingWith: recentBranchArbiter)
        let f = try store.value(id: .init("ABCDEF"), at: mergeVersion.id)!
        #expect(f.data == "Tom".data(using: .utf8))
        #expect(f.storedVersionId == ver2.id)
    }

    @Test func updated() throws {
        let val1 = value("CDEFGH", stringData: "Bob")
        let ver1 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [.update(val1)])
        let ver2 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [])
        let mergeVersion = try store.mergeRelated(version: ver1.id, with: ver2.id, resolvingWith: recentBranchArbiter)
        let f = try store.value(id: .init("CDEFGH"), at: mergeVersion.id)!
        #expect(f.data == "Bob".data(using: .utf8))
        #expect(f.storedVersionId == ver1.id)
    }

    @Test func twiceUpdated() throws {
        let val1 = value("CDEFGH", stringData: "Bob")
        let val2 = value("CDEFGH", stringData: "Tom")
        let ver1 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [.update(val1)])
        let ver2 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [.update(val2)])
        let mergeVersion = try store.mergeRelated(version: ver1.id, with: ver2.id, resolvingWith: recentBranchArbiter)
        let f = try store.value(id: .init("CDEFGH"), at: mergeVersion.id)!
        #expect(f.data == "Tom".data(using: .utf8))
        #expect(f.storedVersionId == ver2.id)
    }

    @Test func removedAndUpdated() throws {
        do {
            let val1 = value("CDEFGH", stringData: "Bob")
            let ver1 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [.update(val1)])
            let ver2 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [.remove(.init("CDEFGH"))])
            let mergeVersion = try store.mergeRelated(version: ver1.id, with: ver2.id, resolvingWith: recentBranchArbiter)
            let f = try store.value(id: .init("CDEFGH"), at: mergeVersion.id)
            #expect(f == nil)
        }

        do {
            let val1 = value("CDEFGH", stringData: "Bob")
            let ver1 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [.remove(.init("CDEFGH"))])
            let ver2 = try store.makeVersion(basedOnPredecessor: origin.id, storing: [.update(val1)])
            let mergeVersion = try store.mergeRelated(version: ver1.id, with: ver2.id, resolvingWith: recentBranchArbiter)
            let f = try store.value(id: .init("CDEFGH"), at: mergeVersion.id)!
            #expect(f.data == "Bob".data(using: .utf8))
            #expect(f.storedVersionId == ver2.id)
        }
    }
}
