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

    func testSendFiles() async throws {
        let val = value("CDEFGH", stringData: "Origin")
        let ver = try store1.makeVersion(basedOnPredecessor: nil, storing: [.insert(val)])
        XCTAssertEqual(changeFiles.count, 0)
        XCTAssertEqual(versionFiles.count, 0)
        let versionIds = try await exchange1.send()
        XCTAssert(versionIds.contains(ver.id))
        XCTAssertEqual(self.changeFiles.count, 1)
        XCTAssertEqual(self.versionFiles.count, 1)
    }

    func testReceiveFiles() async throws {
        let val = value("CDEFGH", stringData: "Origin")
        let ver = try store1.makeVersion(basedOnPredecessor: nil, storing: [.insert(val)])
        let _ = try await exchange1.send()
        let versionIds = try await exchange2.retrieve()
        XCTAssert(versionIds.contains(ver.id))
        XCTAssertEqual(ver, try self.store2.version(identifiedBy: ver.id))
        XCTAssertNotNil(try self.store2.value(id: val.id, at: ver.id))
    }

    func testConcurrentChanges() async throws {
        let origin = try store1.makeVersion(basedOnPredecessor: nil, storing: [])
        let _ = try await exchange1.send()
        let _ = try await exchange2.retrieve()

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

        let _ = try await exchange1.send()
        let _ = try await exchange2.retrieve()
        let _ = try await exchange2.send()
        let _ = try await exchange1.retrieve()

        versions1.forEach { XCTAssertNotNil(try! self.store2.version(identifiedBy: $0.id)) }
        versions2.forEach { XCTAssertNotNil(try! self.store1.version(identifiedBy: $0.id)) }
        for (ver, val) in zip(versions1, values1) {
            let val2 = try self.store2.value(id: val.id, storedAt: ver.id)!
            XCTAssertEqual(val.data, val2.data)
        }
        for (ver, val) in zip(versions2, values2) {
            let val1 = try self.store1.value(id: val.id, storedAt: ver.id)!
            XCTAssertEqual(val.data, val1.data)
        }

        let merge = try store1.mergeRelated(version: versions1.last!.id, with: versions2.last!.id, resolvingWith: MostRecentBranchFavoringArbiter())
        let _ = try await exchange1.send()
        let _ = try await exchange2.retrieve()
        XCTAssertNotNil(try self.store2.version(identifiedBy: merge.id))
        for val in values1 + values2 {
            let val2 = try self.store2.value(id: val.id, at: merge.id)!
            XCTAssertEqual(val.data, val2.data)
        }
    }

    func testNewVersionAvailableNotification() async throws {
        exchange1 = FileSystemExchange(rootDirectoryURL: exchangeURL, store: store1, usesFileCoordination: true)
        exchange2 = FileSystemExchange(rootDirectoryURL: exchangeURL, store: store2, usesFileCoordination: true)

        let _ = try store1.makeVersion(basedOnPredecessor: nil, storing: [])

        // Start listening before the send
        let notificationTask = Task {
            for await _ in exchange2.newVersionsAvailable {
                return // Got a notification
            }
        }

        let _ = try await exchange1.send()

        // Wait for the notification with a timeout
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(3))
        }

        // Race: either we get the notification or we time out
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await notificationTask.value; return true }
            group.addTask { try? await timeoutTask.value; return false }
            let result = await group.next()!
            group.cancelAll()
            if !result {
                XCTFail("Timed out waiting for newVersionsAvailable notification")
            }
        }
    }

    static var allTests: [(String, (FileSystemExchangeTests) -> () async throws -> ())] {
        var result: [(String, (FileSystemExchangeTests) -> () async throws -> ())] = [
            ("testSendFiles", testSendFiles),
            ("testReceiveFiles", testReceiveFiles),
            ("testConcurrentChanges", testConcurrentChanges),
        ]
        result.append(("testNewVersionAvailableNotification", testNewVersionAvailableNotification))
        return result
    }
}
