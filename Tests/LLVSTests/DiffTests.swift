//
//  DiffTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 11/01/2019.
//

import Testing
import Foundation
@testable import LLVS

@Suite class DiffTests {

    let fm = FileManager.default

    let zone: Zone
    let rootURL: URL
    let map: Map

    func add(values: [String], version: String, basedOn: String?) {
        let basedOnVersionId = basedOn.flatMap { Version.ID($0) }
        let versionId = Version.ID(version)
        var deltas: [Map.Delta] = []
        for valueKey in values {
            let valueRef = Value.Reference(valueId: .init(valueKey), storedVersionId: versionId)
            var delta: Map.Delta = .init(key: .init(valueKey))
            delta.addedValueReferences = [valueRef]
            deltas.append(delta)
        }
        try! map.addVersion(versionId, basedOn: basedOnVersionId, applying: deltas)
    }

    func remove(values: [String], version: String, basedOn: String?) {
        let basedOnVersionId = basedOn.flatMap { Version.ID($0) }
        let versionId = Version.ID(version)
        var deltas: [Map.Delta] = []
        for valueKey in values {
            var delta: Map.Delta = .init(key: .init(valueKey))
            delta.removedValueIdentifiers = [.init(valueKey)]
            deltas.append(delta)
        }
        try! map.addVersion(versionId, basedOn: basedOnVersionId, applying: deltas)
    }

    init() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        zone = FileZone(rootDirectory: rootURL, fileExtension: ".txt")
        map = Map(zone: zone)
    }

    deinit {
        try? fm.removeItem(at: rootURL)
    }

    @Test func disjointInserts() throws {
        add(values: ["AB0000"], version: "0000", basedOn: nil)
        add(values: ["AB1111", "AB1155", "CD1111"], version: "1111", basedOn: "0000")
        add(values: ["AB2222", "AB1166", "CD2222"], version: "2222", basedOn: "0000")
        let diffs = try map.differences(between: .init("1111"), and: .init("2222"), withCommonAncestor: .init("0000"))
        #expect(diffs.count == 6)
        #expect(diffs.contains(where: { $0.valueId.rawValue == "AB1111" && $0.valueFork == Value.Fork.inserted(.first) }))
        #expect(diffs.contains(where: { $0.valueId.rawValue == "AB1155" && $0.valueFork == Value.Fork.inserted(.first) }))
        #expect(diffs.contains(where: { $0.valueId.rawValue == "CD1111" && $0.valueFork == Value.Fork.inserted(.first) }))
        #expect(diffs.contains(where: { $0.valueId.rawValue == "AB2222" && $0.valueFork == Value.Fork.inserted(.second) }))
        #expect(diffs.contains(where: { $0.valueId.rawValue == "AB1166" && $0.valueFork == Value.Fork.inserted(.second) }))
        #expect(diffs.contains(where: { $0.valueId.rawValue == "CD2222" && $0.valueFork == Value.Fork.inserted(.second) }))
        #expect(!diffs.contains(where: { $0.valueId.rawValue == "CD2222" && $0.valueFork == Value.Fork.inserted(.first) }))
    }

    @Test func inserts() throws {
        add(values: [], version: "0000", basedOn: nil)
        add(values: ["AB1111", "MM1111"], version: "1111", basedOn: "0000")
        add(values: ["AB1111", "AB1112", "ZZ2222"], version: "2222", basedOn: "0000")
        let diffs = try map.differences(between: .init("1111"), and: .init("2222"), withCommonAncestor: .init("0000"))
        #expect(diffs.count == 4)
        #expect(diffs.contains(where: { $0.valueId.rawValue == "AB1111" && $0.valueFork == Value.Fork.twiceInserted }))
        #expect(diffs.contains(where: { $0.valueId.rawValue == "MM1111" && $0.valueFork == Value.Fork.inserted(.first) }))
        #expect(diffs.contains(where: { $0.valueId.rawValue == "ZZ2222" && $0.valueFork == Value.Fork.inserted(.second) }))
        #expect(diffs.contains(where: { $0.valueId.rawValue == "AB1112" && $0.valueFork == Value.Fork.inserted(.second) }))
    }

    @Test func updates() throws {
        add(values: ["AB1111", "MM1111"], version: "0000", basedOn: nil)
        add(values: ["AB1111"], version: "1111", basedOn: "0000")
        add(values: ["AB1111", "MM1111", "ZZ2222"], version: "2222", basedOn: "0000")
        let diffs = try map.differences(between: .init("1111"), and: .init("2222"), withCommonAncestor: .init("0000"))
        #expect(diffs.count == 3)
        #expect(diffs.contains(where: { $0.valueId.rawValue == "AB1111" && $0.valueFork == Value.Fork.twiceUpdated }))
        #expect(diffs.contains(where: { $0.valueId.rawValue == "MM1111" && $0.valueFork == Value.Fork.updated(.second) }))
        #expect(diffs.contains(where: { $0.valueId.rawValue == "ZZ2222" && $0.valueFork == Value.Fork.inserted(.second) }))
    }

    @Test func removes() throws {
        add(values: ["AB1111", "MM1111", "ZZ2222"], version: "0000", basedOn: nil)
        remove(values: ["AB1111", "MM1111"], version: "1111", basedOn: "0000")
        remove(values: ["AB1111", "ZZ2222"], version: "2222", basedOn: "0000")
        let diffs = try map.differences(between: .init("1111"), and: .init("2222"), withCommonAncestor: .init("0000"))
        #expect(diffs.count == 3)
        #expect(diffs.contains(where: { $0.valueId.rawValue == "AB1111" && $0.valueFork == Value.Fork.twiceRemoved }))
        #expect(diffs.contains(where: { $0.valueId.rawValue == "MM1111" && $0.valueFork == Value.Fork.removed(.first) }))
        #expect(diffs.contains(where: { $0.valueId.rawValue == "ZZ2222" && $0.valueFork == Value.Fork.removed(.second) }))
    }

    @Test func updateRemove() throws {
        add(values: ["AB1111"], version: "0000", basedOn: nil)
        remove(values: ["AB1111"], version: "1111", basedOn: "0000")
        add(values: ["AB1111"], version: "2222", basedOn: "0000")
        let diffs = try map.differences(between: .init("1111"), and: .init("2222"), withCommonAncestor: .init("0000"))
        #expect(diffs.count == 1)
        #expect(diffs.contains(where: { $0.valueId.rawValue == "AB1111" && $0.valueFork == Value.Fork.removedAndUpdated(removedOn: .first) }))
    }

    @Test func unchangedBucketsProduceNoDiffs() throws {
        add(values: ["AB0000", "ZZ0000"], version: "0000", basedOn: nil)
        add(values: ["AB1111"], version: "1111", basedOn: "0000")
        add(values: ["AB2222"], version: "2222", basedOn: "0000")
        let diffs = try map.differences(between: .init("1111"), and: .init("2222"), withCommonAncestor: .init("0000"))
        // Only "AB" bucket changed; "ZZ" bucket is identical in both branches
        #expect(diffs.allSatisfy({ $0.valueId.rawValue.hasPrefix("AB") }))
        #expect(!diffs.contains(where: { $0.valueId.rawValue == "ZZ0000" }))
    }

    @Test func oneBranchUnchangedBucket() throws {
        add(values: ["AB0000", "ZZ0000"], version: "0000", basedOn: nil)
        add(values: ["AB1111"], version: "1111", basedOn: "0000")
        add(values: ["ZZ2222"], version: "2222", basedOn: "0000")
        let diffs = try map.differences(between: .init("1111"), and: .init("2222"), withCommonAncestor: .init("0000"))
        #expect(diffs.contains(where: { $0.valueId.rawValue == "AB1111" && $0.valueFork == Value.Fork.inserted(.first) }))
        #expect(diffs.contains(where: { $0.valueId.rawValue == "ZZ2222" && $0.valueFork == Value.Fork.inserted(.second) }))
    }
}
