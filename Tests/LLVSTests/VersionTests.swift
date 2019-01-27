//
//  VersionTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 26/01/2019.
//

import XCTest
import Foundation
@testable import LLVS

final class VersionTests: XCTestCase {
    
    let fm = FileManager.default
    
    var store: Store!
    var rootURL: URL!
    var versionsURL: URL!
    var version: Version!
    
    override func setUp() {
        super.setUp()
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        versionsURL = rootURL.appendingPathComponent("versions")
        store = try! Store(rootDirectoryURL: rootURL)
        version = try! store.addVersion(basedOn: nil, storing: [])
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: rootURL)
        super.tearDown()
    }
    
    func testCreationOfVersionFile() {
        let v = version.identifier.identifierString + ".json"
        let prefix = String(v.prefix(2))
        let postfix = String(v.dropFirst(2))
        XCTAssert(fm.fileExists(atPath: versionsURL.appendingPathComponent(prefix).appendingPathComponent(postfix).path))
    }
    
    func testLoadingOfVersion() {
        store = try! Store(rootDirectoryURL: rootURL)
        XCTAssertEqual(store.history.headIdentifiers, [version.identifier])
    }

    static var allTests = [
        ("testCreationOfVersionFile", testCreationOfVersionFile),
        ("testLoadingOfVersion", testLoadingOfVersion),
    ]
}
