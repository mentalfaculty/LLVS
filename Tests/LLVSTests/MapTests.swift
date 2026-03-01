//
//  MapTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 09/12/2018.
//

import Testing
import Foundation
@testable import LLVS

@Suite class MapTests {

    let fm = FileManager.default

    let zone: Zone
    let rootURL: URL
    let map: Map

    init() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        zone = FileZone(rootDirectory: rootURL, fileExtension: ".txt")
        map = Map(zone: zone)
    }

    deinit {
        try? fm.removeItem(at: rootURL)
    }

    @Test func firstCommit() throws {
        let valueKey = "ABCD"
        let versionId = Version.ID("1234")
        let valueRef = Value.Reference(valueId: .init(valueKey), storedVersionId: versionId)
        var delta: Map.Delta = .init(key: .init(valueKey))
        delta.addedValueReferences = [valueRef]
        try map.addVersion(versionId, basedOn: nil, applying: [delta])
        let valueRefs = try map.valueReferences(matching: .init(valueKey), at: versionId)
        #expect(valueRefs.count == 1)
        #expect(valueRefs.first! == Value.Reference(valueId: .init(valueKey), storedVersionId: versionId))
    }

    @Test func fetchingValueFromEarlierCommit() throws {
        let valueKey = "ABCD"
        var delta: Map.Delta = .init(key: .init(valueKey))
        let versionId = Version.ID("1234")
        let valueRef = Value.Reference(valueId: .init(valueKey), storedVersionId: versionId)
        delta.addedValueReferences = [valueRef]
        try map.addVersion(.init("1234"), basedOn: nil, applying: [delta])
        try map.addVersion(.init("2345"), basedOn: .init("1234"), applying: [])
        let valueRefs = try map.valueReferences(matching: .init(valueKey), at: .init("2345"))
        #expect(valueRefs.count == 1)
        #expect(valueRefs.first! == Value.Reference(valueId: .init(valueKey), storedVersionId: .init("1234")))
    }

    @Test func removingValue() throws {
        let valueKey1 = "ABCD"
        var delta1: Map.Delta = .init(key: .init(valueKey1))
        let versionId1 = Version.ID("1234")
        let valueRef1 = Value.Reference(valueId: .init(valueKey1), storedVersionId: versionId1)
        delta1.addedValueReferences = [valueRef1]
        try map.addVersion(versionId1, basedOn: nil, applying: [delta1])

        let valueKey2 = "BCDE"
        let versionId2 = Version.ID("2345")
        var delta21: Map.Delta = .init(key: .init(valueKey1))
        delta21.removedValueIdentifiers = [.init(valueKey1)]
        var delta22: Map.Delta = .init(key: .init(valueKey2))
        let valueRef2 = Value.Reference(valueId: .init(valueKey2), storedVersionId: versionId2)
        delta22.addedValueReferences = [valueRef2]
        try map.addVersion(.init("2345"), basedOn: .init("1234"), applying: [delta21, delta22])

        var valueRefs = try map.valueReferences(matching: .init(valueKey1), at: .init("2345"))
        #expect(valueRefs.count == 0)

        valueRefs = try map.valueReferences(matching: .init(valueKey2), at: .init("2345"))
        #expect(valueRefs.count == 1)
        #expect(valueRefs.first! == Value.Reference(valueId: .init(valueKey2), storedVersionId: .init("2345")))
    }

    @Test func oneToManyMap() throws {
        var delta1: Map.Delta = .init(key: .init("Amsterdam"))
        let valueRef1 = Value.Reference(valueId: .init("ABCD"), storedVersionId: .init("1234"))
        delta1.addedValueReferences = [valueRef1]
        try map.addVersion(valueRef1.storedVersionId, basedOn: nil, applying: [delta1])

        var delta2: Map.Delta = .init(key: .init("Amsterdam"))
        let valueRef2 = Value.Reference(valueId: .init("CDEF"), storedVersionId: .init("2345"))
        delta2.addedValueReferences = [valueRef2]
        try map.addVersion(valueRef2.storedVersionId, basedOn: .init("1234"), applying: [delta2])

        var valueRefs = try map.valueReferences(matching: .init("Amsterdam"), at: .init("2345"))
        #expect(valueRefs.count == 2)
        #expect(valueRefs.contains(.init(valueId: .init("ABCD"), storedVersionId: .init("1234"))))
        #expect(valueRefs.contains(.init(valueId: .init("CDEF"), storedVersionId: .init("2345"))))

        var delta3: Map.Delta = .init(key: .init("Amsterdam"))
        delta3.removedValueIdentifiers = [.init("ABCD")]
        try map.addVersion(.init("3456"), basedOn: .init("2345"), applying: [delta3])

        valueRefs = try map.valueReferences(matching: .init("Amsterdam"), at: .init("3456"))
        #expect(valueRefs.count == 1)
        #expect(valueRefs.contains(.init(valueId: .init("CDEF"), storedVersionId: .init("2345"))))
    }

    @Test func similarKeys() throws {
        var delta1: Map.Delta = .init(key: .init("Amsterdam"))
        let valueRef1 = Value.Reference(valueId: .init("ABCD"), storedVersionId: .init("1234"))
        delta1.addedValueReferences = [valueRef1]
        try map.addVersion(valueRef1.storedVersionId, basedOn: nil, applying: [delta1])

        var delta2: Map.Delta = .init(key: .init("Amsterdam1"))
        let valueRef2 = Value.Reference(valueId: .init("CDEF"), storedVersionId: .init("2345"))
        delta2.addedValueReferences = [valueRef2]
        try map.addVersion(valueRef2.storedVersionId, basedOn: .init("1234"), applying: [delta2])

        do {
            let valueRefs = try map.valueReferences(matching: .init("Amsterdam"), at: .init("2345"))
            #expect(valueRefs.count == 1)
            #expect(valueRefs.contains(.init(valueId: .init("ABCD"), storedVersionId: .init("1234"))))
        }

        do {
            let valueRefs = try map.valueReferences(matching: .init("Amsterdam1"), at: .init("2345"))
            #expect(valueRefs.count == 1)
            #expect(valueRefs.contains(.init(valueId: .init("CDEF"), storedVersionId: .init("2345"))))
        }
    }
}
