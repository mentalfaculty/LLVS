//
//  FileSystemExchangeTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 08/03/2019.
//

import XCTest
import Foundation
@testable import LLVS

class FileSystemExchangeTests: XCTestCase {

    let fm = FileManager.default
    
    var store1, store2: Store!
    var rootURL1, rootURL2: URL!
    var exchangeURL: URL!
    var exchange1, exchange2: FileSystemExchange!
    
    var recentChangeArbiter: MostRecentChangeFavoringArbiter!
    
    override func setUp() {
        super.setUp()
        rootURL1 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        rootURL2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store1 = try! Store(rootDirectoryURL: rootURL1)
        store2 = try! Store(rootDirectoryURL: rootURL2)
        recentChangeArbiter = MostRecentChangeFavoringArbiter()
        exchangeURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        exchange1 = FileSystemExchange(rootDirectoryURL: exchangeURL, store: store1)
        exchange2 = FileSystemExchange(rootDirectoryURL: exchangeURL, store: store2)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: rootURL1)
        try? FileManager.default.removeItem(at: rootURL2)
        try? FileManager.default.removeItem(at: exchangeURL)
        super.tearDown()
    }
    
    private func value(_ identifier: String, stringData: String) -> Value {
        return Value(identifier: .init(identifier), version: nil, data: stringData.data(using: .utf8)!)
    }
    
    func testExchangeDirContainsFiles() {
        let val = value("CDEFGH", stringData: "Origin")
        let ver = try! store1.addVersion(basedOnPredecessor: nil, storing: [.insert(val)])
        XCTAssertEqual(try! fm.contentsOfDirectory(at: exchangeURL.appendingPathComponent("changes"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).count, 0)
        XCTAssertEqual(try! fm.contentsOfDirectory(at: exchangeURL.appendingPathComponent("versions"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).count, 0)
        let expect = self.expectation(description: "Send")
        exchange1.send { result in
            if case let .success(versionIds) = result {
                XCTAssert(versionIds.contains(ver.identifier))
            } else {
                XCTFail()
            }
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)
    }

    static var allTests = [
        ("testExchangeDirContainsFiles", testExchangeDirContainsFiles),
    ]
}
