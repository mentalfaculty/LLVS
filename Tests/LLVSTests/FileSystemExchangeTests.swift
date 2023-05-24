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
        exchange1 = FileSystemExchange(rootDirectoryURL: exchangeURL, store: store1, usesFileCoordination: false)
        exchange2 = FileSystemExchange(rootDirectoryURL: exchangeURL, store: store2, usesFileCoordination: false)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: rootURL1)
        try? FileManager.default.removeItem(at: rootURL2)
        try? FileManager.default.removeItem(at: exchangeURL)
        super.tearDown()
    }
    
    private func value(_ identifier: String, stringData: String) -> Value {
        return Value(id: .init(identifier), data: stringData.data(using: .utf8)!)
    }
    
    private var changeFiles: [URL] {
        return try! fm.contentsOfDirectory(at: exchangeURL.appendingPathComponent("changes"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    }
    
    private var versionFiles: [URL] {
        return try! fm.contentsOfDirectory(at: exchangeURL.appendingPathComponent("versions"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    }
    
    func testSendFiles() {
        let val = value("CDEFGH", stringData: "Origin")
        let ver = try! store1.makeVersion(basedOnPredecessor: nil, storing: [.insert(val)])
        XCTAssertEqual(changeFiles.count, 0)
        XCTAssertEqual(versionFiles.count, 0)
        let expect = self.expectation(description: "Send")
        exchange1.send { result in
            if case let .success(versionIds) = result {
                XCTAssert(versionIds.contains(ver.id))
                XCTAssertEqual(self.changeFiles.count, 1)
                XCTAssertEqual(self.versionFiles.count, 1)
            } else {
                XCTFail()
            }
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)
    }
    
    func testReceiveFiles() {
        let val = value("CDEFGH", stringData: "Origin")
        let ver = try! store1.makeVersion(basedOnPredecessor: nil, storing: [.insert(val)])
        let expect = self.expectation(description: "Retrieve")
        exchange1.send { _ in
            self.exchange2.retrieve { result in
                if case let .success(versionIds) = result {
                    XCTAssert(versionIds.contains(ver.id))
                    XCTAssertEqual(ver, try! self.store2.version(identifiedBy: ver.id))
                    XCTAssertNotNil(try! self.store2.value(id: val.id, at: ver.id))
                } else {
                    XCTFail()
                }
                expect.fulfill()
            }
        }
        wait(for: [expect], timeout: 1.0)
    }
    
    func testConcurrentChanges() {
        let expectOrigin = self.expectation(description: "Share Origin")
        let origin = try! store1.makeVersion(basedOnPredecessor: nil, storing: [])
        exchange1.send { _ in
            self.exchange2.retrieve { result in
                expectOrigin.fulfill()
            }
        }
        wait(for: [expectOrigin], timeout: 1.0)
        
        func add(numberOfVersions: Int, store: Store) -> ([Version], [Value]) {
            var versions: [Version] = []
            var values: [Value] = []
            for _ in 0..<numberOfVersions {
                let id = UUID().uuidString
                let val = value(id, stringData: id)
                let ver = try! store.makeVersion(basedOnPredecessor: versions.last?.id ?? origin.id, storing: [.insert(val)])
                versions.append(ver)
                values.append(val)
            }
            return (versions, values)
        }

        let (versions1, values1) = add(numberOfVersions: 3, store: store1)
        let (versions2, values2) = add(numberOfVersions: 3, store: store2)
        
        let expect = self.expectation(description: "Sync")
        exchange1.send { _ in
            self.exchange2.retrieve { result in
                self.exchange2.send { _ in
                    self.exchange1.retrieve { result in
                        versions1.forEach { XCTAssertNotNil(try! self.store2.version(identifiedBy: $0.id)) }
                        versions2.forEach { XCTAssertNotNil(try! self.store1.version(identifiedBy: $0.id)) }
                        for (ver, val) in zip(versions1, values1) {
                            let val2 = try! self.store2.value(id: val.id, storedAt: ver.id)!
                            XCTAssertEqual(val.data, val2.data)
                        }
                        for (ver, val) in zip(versions2, values2) {
                            let val1 = try! self.store1.value(id: val.id, storedAt: ver.id)!
                            XCTAssertEqual(val.data, val1.data)
                        }
                        expect.fulfill()
                    }
                }
            }
        }
        wait(for: [expect], timeout: 10.0)
        
        let merge = try! store1.mergeRelated(version: versions1.last!.id, with: versions2.last!.id, resolvingWith: MostRecentBranchFavoringArbiter())
        let expectMerge = self.expectation(description: "Merge")
        exchange1.send { _ in
            self.exchange2.retrieve { result in
                XCTAssertNotNil(try! self.store2.version(identifiedBy: merge.id))
                for val in values1 + values2 {
                    let val2 = try! self.store2.value(id: val.id, at: merge.id)!
                    XCTAssertEqual(val.data, val2.data)
                }
                expectMerge.fulfill()
            }
        }
        wait(for: [expectMerge], timeout: 1.0)
    }
    
    var publisher: Any?
    
    func testNewVersionAvailableNotification() {
        exchange1 = FileSystemExchange(rootDirectoryURL: exchangeURL, store: store1, usesFileCoordination: true)
        exchange2 = FileSystemExchange(rootDirectoryURL: exchangeURL, store: store2, usesFileCoordination: true)
    
        let expect = self.expectation(description: "Send")
        publisher = exchange2.newVersionsAvailable.first().sink {
            expect.fulfill()
        }
        
        let _ = try! store1.makeVersion(basedOnPredecessor: nil, storing: [])
        
        exchange1.send { _ in }
        wait(for: [expect], timeout: 3.0)
    }

    static var allTests: [(String, (FileSystemExchangeTests) -> () -> ())] {
        var result = [
            ("testSendFiles", testSendFiles),
            ("testReceiveFiles", testReceiveFiles),
            ("testConcurrentChanges", testConcurrentChanges)
        ]
        result.append(("testNewVersionAvailableNotification", testNewVersionAvailableNotification))
        return result
    }
}
