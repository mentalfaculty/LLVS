//
//  AsynchronousTaskTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 04/03/2019.
//

import XCTest
import LLVS

class AsynchronousTaskTests: XCTestCase {
    
    var task1: AsynchronousTask!
    var task2: AsynchronousTask!
    
    override func setUp() {
        super.setUp()
        task1 = AsynchronousTask { finish in
            finish(.success)
        }
        task2 = AsynchronousTask { finish in
            finish(.success)
        }
    }
    
    func testNextTask() {
        let expect = XCTestExpectation(description: "Completed basic")
        task1.next = task2
        task2.completionBlock = { result in
            XCTAssert(result.success)
            expect.fulfill()
        }
        task1.execute()
        wait(for: [expect], timeout: 1.0)
    }
    
    func testChain() {
        let expect = XCTestExpectation(description: "Completed basic")
        [task1, task2].chain()
        task2.completionBlock = { result in
            XCTAssert(result.success)
            expect.fulfill()
        }
        task1.execute()
        wait(for: [expect], timeout: 1.0)
    }
    
    func testExecuteInOrder() {
        let expect = XCTestExpectation(description: "Completed Execute in Order")
        let task3 = AsynchronousTask { finish in
            finish(.success)
        }
        let task4 = AsynchronousTask { finish in
            finish(.success)
        }
        [task1, task2, task3, task4].executeInOrder { result in
            XCTAssert(result.success)
            expect.fulfill()
        }
        task1.execute()
        wait(for: [expect], timeout: 1.0)
    }
    
    func testWithAsyncDelay() {
        let expect = XCTestExpectation(description: "Completed with Async Delay")
        let task3 = AsynchronousTask { finish in
            DispatchQueue.main.async {
                finish(.success)
            }
        }
        [task1, task2, task3].executeInOrder { result in
            XCTAssert(result.success)
            expect.fulfill()
        }
        task1.execute()
        wait(for: [expect], timeout: 1.0)
    }
    
    enum Error: Swift.Error {
        case testError
    }
    
    func testWithFailure() {
        let expect = XCTestExpectation(description: "Test with failure")
        let task3 = AsynchronousTask { finish in
            finish(.failure(Error.testError))
        }
        var task4Executed = false
        let task4 = AsynchronousTask { finish in
            task4Executed = true
            finish(.success)
        }
        [task1, task2, task3, task4].executeInOrder { result in
            XCTAssertFalse(task4Executed)
            XCTAssertFalse(result.success)
            expect.fulfill()
        }
        task1.execute()
        wait(for: [expect], timeout: 1.0)
    }

    static var allTests = [
        ("testNextTask", testNextTask),
        ("testChain", testChain),
        ("testExecuteInOrder", testExecuteInOrder),
        ("testWithFailure", testWithFailure),
    ]
}
