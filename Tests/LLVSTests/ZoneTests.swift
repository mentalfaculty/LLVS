//
//  ZoneTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 07/12/2018.
//

import XCTest
import Foundation
@testable import LLVS

class ZoneTests: XCTestCase {

    let fm = FileManager.default
    
    var zone: FileZone!
    var rootURL: URL!
    var ref: ZoneReference!
    
    override func setUp() {
        super.setUp()

        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        zone = FileZone(rootDirectory: rootURL, fileExtension: "json")
        ref = ZoneReference(key: "ABCDEF", version: .init("1234"))
    }
    
    override func tearDown() {
        try? fm.removeItem(at: rootURL)
        super.tearDown()
    }
    
    func testCreation() {
        XCTAssert(fm.fileExists(atPath: rootURL.path))
    }
    
    func testAddingDataCreatesFiles() {
        XCTAssertNoThrow(try zone.store(Data(), for: ref))
        fm.fileExists(atPath: rootURL.appendingPathComponent("AB/CDEF/1/234.json").path)
    }
    
    func testAddingMultipleReferencesInSameDiretories() {
        XCTAssertNoThrow(try zone.store(Data(), for: ref))
        XCTAssertNoThrow(try zone.store(Data(), for: .init(key: "ABCDEF", version: .init("1245"))))
        fm.fileExists(atPath: rootURL.appendingPathComponent("AB/CDEF/1/245.json").path)
    }
    
    func testAddingMultipleReferencesWithDifferentVersionDirectories() {
        XCTAssertNoThrow(try zone.store(Data(), for: ref))
        XCTAssertNoThrow(try zone.store(Data(), for: .init(key: "ABCDEF", version: .init("2222"))))
        fm.fileExists(atPath: rootURL.appendingPathComponent("AB/CDEF/2/222.json").path)
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
        let versionStrings = versions.map { $0.stringValue }
        XCTAssertEqual(versions.count, 2)
        XCTAssert(versionStrings.contains("1234"))
        XCTAssert(versionStrings.contains("1245"))
    }
    
    static var allTests = [
        ("testCreation", testCreation),
        ("testAddingDataCreatesFiles", testAddingDataCreatesFiles),
        ("testAddingMultipleReferencesInSameDiretories", testAddingMultipleReferencesInSameDiretories),
        ("testAddingMultipleReferencesWithDifferentVersionDirectories", testAddingMultipleReferencesWithDifferentVersionDirectories),
        ("testRetrievingNonExistentData", testRetrievingNonExistentData),
        ("testRetrievingData", testRetrievingData),
        ("testVersionsQuery", testVersionsQuery),
    ]
}
