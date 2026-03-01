//
//  SQLiteZoneTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 16/02/2022.
//

import Testing
import Foundation
@testable import LLVS
@testable import LLVSSQLite

@Suite class SQLiteZoneTests {

    let fm = FileManager.default

    let zone: SQLiteZone
    let rootURL: URL
    let ref: ZoneReference

    init() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        zone = try SQLiteZone(rootDirectory: rootURL, fileExtension: "sqlite")
        ref = ZoneReference(key: "ABCDEF", version: .init("1234"))
    }

    deinit {
        try? zone.dismantle()
        try? fm.removeItem(at: rootURL)
    }

    @Test func creation() {
        #expect(fm.fileExists(atPath: rootURL.path))
        #expect(fm.fileExists(atPath: rootURL.appendingPathComponent("zone.sqlite").path))
    }

    @Test func addingMultipleReferencesWithSameKey() throws {
        try zone.store(Data(), for: ref)
        try zone.store(Data(), for: .init(key: ref.key, version: .init("1245")))
    }

    @Test func addingMultipleReferencesWithSameVersion() throws {
        try zone.store(Data(), for: ref)
        try zone.store(Data(), for: .init(key: "ABCDEFG", version: ref.version))
    }

    @Test func retrievingNonExistentData() throws {
        let data = try zone.data(for: ref)
        #expect(data == nil)
    }

    @Test func retrievingData() throws {
        try zone.store("Test".data(using: .utf8)!, for: ref)
        let data = try zone.data(for: ref)
        #expect(data != nil)
        let string = String(bytes: data!, encoding: .utf8)
        #expect(string == "Test")
    }

    @Test func versionsQuery() throws {
        try zone.store(Data(), for: ref)
        try zone.store(Data(), for: .init(key: "ABCDEF", version: .init("1245")))
        let versions = try zone.versionIds(for: "ABCDEF")
        let versionStrings = versions.map { $0.rawValue }
        #expect(versions.count == 2)
        #expect(versionStrings.contains("1234"))
        #expect(versionStrings.contains("1245"))
    }
}
