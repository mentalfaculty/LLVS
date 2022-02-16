//
//  SQLiteZoneTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 16/02/2022.
//

import XCTest
import Foundation
@testable import LLVS
@testable import LLVSSQLite

class SQLiteZoneTests: XCTestCase {

    let fm = FileManager.default
    
    var zone: SQLiteZone!
    var rootURL: URL!
    var ref: ZoneReference!
    
    override func setUp() {
        super.setUp()

        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        zone = try! SQLiteZone(rootDirectory: rootURL, fileExtension: "sqlite")
        ref = ZoneReference(key: "ABCDEF", version: .init("1234"))
    }
    
    override func tearDown() {
        try? zone.dismantle()
        try? fm.removeItem(at: rootURL)
        super.tearDown()
    }
    
    func testCreation() {
        XCTAssert(fm.fileExists(atPath: rootURL.path))
        XCTAssert(fm.fileExists(atPath: rootURL.appendingPathComponent("zone.sqlite").path))
    }
    
    func testAddingMultipleReferencesWithSameKey() {
        XCTAssertNoThrow(try zone.store(Data(), for: ref))
        XCTAssertNoThrow(try zone.store(Data(), for: .init(key: ref.key, version: .init("1245"))))
    }
    
    func testAddingMultipleReferencesWithSameVersion() {
        XCTAssertNoThrow(try zone.store(Data(), for: ref))
        XCTAssertNoThrow(try zone.store(Data(), for: .init(key: "ABCDEFG", version: ref.version)))
    }
    
    func testRetrievingNonExistentData() {
        let data = try! zone.data(for: ref)
        XCTAssertNil(data)
    }
    
    func testRetrievingData() {
        try! zone.store("Test".data(using: .utf8)!, for: ref)
        let data = try! zone.data(for: ref)
        XCTAssertNotNil(data)
        let string = String(bytes: data!, encoding: .utf8)
        XCTAssertEqual(string, "Test")
    }
    
    func testVersionsQuery() {
        try! zone.store(Data(), for: ref)
        try! zone.store(Data(), for: .init(key: "ABCDEF", version: .init("1245")))
        let versions = try! zone.versionIds(for: "ABCDEF")
        let versionStrings = versions.map { $0.rawValue }
        XCTAssertEqual(versions.count, 2)
        XCTAssert(versionStrings.contains("1234"))
        XCTAssert(versionStrings.contains("1245"))
    }
    
    static var allTests = [
        ("testCreation", testCreation),
        ("testAddingMultipleReferencesWithSameKey", testAddingMultipleReferencesWithSameKey),
        ("testAddingMultipleReferencesWithSameVersion", testAddingMultipleReferencesWithSameVersion),
        ("testRetrievingNonExistentData", testRetrievingNonExistentData),
        ("testRetrievingData", testRetrievingData),
        ("testVersionsQuery", testVersionsQuery),
    ]
}
