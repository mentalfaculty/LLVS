//
//  MemoryExchangeTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 01/03/2026.
//

import XCTest
import Foundation
@testable import LLVS

class MemoryExchangeTests: XCTestCase {

    let fm = FileManager.default

    var store1, store2: Store!
    var rootURL1, rootURL2: URL!
    var exchange1, exchange2: MemoryExchange!

    override func setUp() {
        super.setUp()
        rootURL1 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        rootURL2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store1 = try! Store(rootDirectoryURL: rootURL1)
        store2 = try! Store(rootDirectoryURL: rootURL2)

        // Both exchanges share the same in-memory storage by using a shared instance
        // that both stores send to / retrieve from. We create a "hub" exchange for store1
        // and a second exchange for store2, but to simulate a shared remote we use a
        // single MemoryExchange as the intermediary.
        exchange1 = MemoryExchange(store: store1)
        exchange2 = MemoryExchange(store: store2)
    }

    override func tearDown() {
        try? fm.removeItem(at: rootURL1)
        try? fm.removeItem(at: rootURL2)
        super.tearDown()
    }

    private func value(_ identifier: String, stringData: String) -> Value {
        return Value(id: .init(identifier), data: stringData.data(using: .utf8)!)
    }

    /// Helper that sends from store1's exchange to a shared MemoryExchange,
    /// then retrieves into store2. Since MemoryExchange is an in-process buffer,
    /// we wire send/retrieve through a single shared instance acting as the "cloud."
    private func syncStore1ToStore2(shared: MemoryExchange, completion: @escaping (Result<[Version.ID], Error>) -> Void) {
        exchange1.send { sendResult in
            guard case .success = sendResult else {
                completion(sendResult)
                return
            }
            // Copy versions from exchange1's storage into shared, then retrieve into store2
            // Actually, the simplest approach: send from store1 via shared, retrieve into store2 via shared
            shared.send { _ in
                self.exchange2.retrieve { retrieveResult in
                    completion(retrieveResult)
                }
            }
        }
    }

    // MARK: - Tests

    func testSendPopulatesExchange() {
        let val = value("CDEFGH", stringData: "Origin")
        let ver = try! store1.makeVersion(basedOnPredecessor: nil, storing: [.insert(val)])

        let expect = self.expectation(description: "Send")
        exchange1.send { result in
            if case let .success(versionIds) = result {
                XCTAssert(versionIds.contains(ver.id))
            } else {
                XCTFail()
            }
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)
    }

    func testRetrieveFromSharedExchange() {
        // Use a shared MemoryExchange as the "remote" for both stores
        let shared = MemoryExchange(store: store1)
        let exchange2WithShared = MemoryExchange(store: store2)

        let val = value("CDEFGH", stringData: "Origin")
        let ver = try! store1.makeVersion(basedOnPredecessor: nil, storing: [.insert(val)])

        let expect = self.expectation(description: "Retrieve")

        // Send store1's versions into the shared exchange
        shared.send { _ in
            // Now manually populate exchange2WithShared with same data
            // by retrieving version info from shared and sending to exchange2WithShared
            shared.retrieveAllVersionIdentifiers { idsResult in
                guard case let .success(ids) = idsResult else { XCTFail(); return }

                shared.retrieveVersions(identifiedBy: ids) { versionsResult in
                    guard case let .success(versions) = versionsResult else { XCTFail(); return }

                    shared.retrieveValueChanges(forVersionsIdentifiedBy: ids) { changesResult in
                        guard case let .success(changesByVersion) = changesResult else { XCTFail(); return }

                        let versionChanges: [VersionChanges] = versions.map { v in
                            (v, changesByVersion[v.id] ?? [])
                        }

                        // Populate exchange2WithShared so store2 can retrieve
                        exchange2WithShared.send(versionChanges: versionChanges) { _ in
                            exchange2WithShared.retrieve { result in
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
                    }
                }
            }
        }
        wait(for: [expect], timeout: 1.0)
    }

    func testSendAndRetrieveMultipleVersions() {
        let val1 = value("AAA", stringData: "First")
        let ver1 = try! store1.makeVersion(basedOnPredecessor: nil, storing: [.insert(val1)])
        let val2 = value("BBB", stringData: "Second")
        let ver2 = try! store1.makeVersion(basedOnPredecessor: ver1.id, storing: [.insert(val2)])

        let expect = self.expectation(description: "Send")
        exchange1.send { result in
            if case let .success(versionIds) = result {
                XCTAssertEqual(versionIds.count, 2)
                XCTAssert(versionIds.contains(ver1.id))
                XCTAssert(versionIds.contains(ver2.id))
            } else {
                XCTFail()
            }
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        // Verify data is in exchange
        let expectRetrieve = self.expectation(description: "RetrieveIds")
        exchange1.retrieveAllVersionIdentifiers { result in
            if case let .success(ids) = result {
                XCTAssertEqual(ids.count, 2)
            } else {
                XCTFail()
            }
            expectRetrieve.fulfill()
        }
        wait(for: [expectRetrieve], timeout: 1.0)
    }

    func testRetrieveVersionsById() {
        let val = value("CDEFGH", stringData: "Origin")
        let ver = try! store1.makeVersion(basedOnPredecessor: nil, storing: [.insert(val)])

        let expect = self.expectation(description: "Send then retrieve versions")
        exchange1.send { _ in
            self.exchange1.retrieveVersions(identifiedBy: [ver.id]) { result in
                if case let .success(versions) = result {
                    XCTAssertEqual(versions.count, 1)
                    XCTAssertEqual(versions.first?.id, ver.id)
                } else {
                    XCTFail()
                }
                expect.fulfill()
            }
        }
        wait(for: [expect], timeout: 1.0)
    }

    func testRetrieveValueChanges() {
        let val = value("CDEFGH", stringData: "Origin")
        let ver = try! store1.makeVersion(basedOnPredecessor: nil, storing: [.insert(val)])

        let expect = self.expectation(description: "Send then retrieve changes")
        exchange1.send { _ in
            self.exchange1.retrieveValueChanges(forVersionsIdentifiedBy: [ver.id]) { result in
                if case let .success(changesByVersion) = result {
                    XCTAssertEqual(changesByVersion.count, 1)
                    XCTAssertEqual(changesByVersion[ver.id]?.count, 1)
                } else {
                    XCTFail()
                }
                expect.fulfill()
            }
        }
        wait(for: [expect], timeout: 1.0)
    }

    func testRetrieveMissingVersionsReturnsEmpty() {
        let fakeId = Version.ID(UUID().uuidString)
        let expect = self.expectation(description: "Retrieve missing")
        exchange1.retrieveVersions(identifiedBy: [fakeId]) { result in
            if case let .success(versions) = result {
                XCTAssertEqual(versions.count, 0)
            } else {
                XCTFail()
            }
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)
    }

    func testRestorationStateIsNil() {
        XCTAssertNil(exchange1.restorationState)
        exchange1.restorationState = Data([1, 2, 3])
        XCTAssertNil(exchange1.restorationState)
    }

    func testNewVersionsAvailablePublisher() {
        var publisher: Any?
        let expect = self.expectation(description: "Notification")

        publisher = exchange1.newVersionsAvailable.first().sink {
            expect.fulfill()
        }

        let _ = try! store1.makeVersion(basedOnPredecessor: nil, storing: [])
        exchange1.send { _ in }

        wait(for: [expect], timeout: 1.0)
        _ = publisher // Silence unused variable warning
    }

    func testSendEmptyIsNoOp() {
        // Exchange with no versions in store should send nothing
        let expect = self.expectation(description: "Send empty")
        exchange1.send { result in
            if case let .success(ids) = result {
                XCTAssertEqual(ids.count, 0)
            } else {
                XCTFail()
            }
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)
    }

    func testSendIdempotent() {
        let val = value("CDEFGH", stringData: "Origin")
        let _ = try! store1.makeVersion(basedOnPredecessor: nil, storing: [.insert(val)])

        let expect = self.expectation(description: "Idempotent send")
        exchange1.send { result1 in
            guard case let .success(ids1) = result1 else { XCTFail(); return }
            XCTAssertEqual(ids1.count, 1)

            // Second send should have nothing new to send
            self.exchange1.send { result2 in
                if case let .success(ids2) = result2 {
                    XCTAssertEqual(ids2.count, 0)
                } else {
                    XCTFail()
                }
                expect.fulfill()
            }
        }
        wait(for: [expect], timeout: 1.0)
    }
}
