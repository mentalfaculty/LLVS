//
//  DynamicTaskBatcherTests.swift
//  
//
//  Created by Drew McCormack on 06/03/2020.
//

import Foundation

import XCTest
import Foundation
@testable import LLVS

class DynamicTaskBatcherTests: XCTestCase {
    
    enum TestError: Swift.Error {
        case testError
    }
    
    func testFailure() {
        var count = 0
        let batcher = DynamicTaskBatcher(numberOfTasks: 10, taskCostEvaluator: { _ in 0.1 }) { range, finish in
            count += 1
            finish(.definitive(.failure(TestError.testError)))
        }
        
        let expect = self.expectation(description: "executing")
        batcher.start { result in
            XCTAssertFalse(result.isSuccess)
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)
        XCTAssertEqual(count, 1)
    }
    
    func testZeroTasks() {
        let batcher = DynamicTaskBatcher(numberOfTasks: 0, taskCostEvaluator: { _ in 0.1 }, batchExecuter: { _, _ in })
        let expect = self.expectation(description: "executing")
        batcher.start { result in
            XCTAssertTrue(result.isSuccess)
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)
    }
    
    func testOneTask() {
        var count = 0
        let batcher = DynamicTaskBatcher(numberOfTasks: 1, taskCostEvaluator: { _ in 0.1 }) { range, finish in
            count += 1
            XCTAssertEqual(range, 0..<1)
            finish(.definitive(.success(())))
        }
        
        let expect = self.expectation(description: "executing")
        batcher.start { result in
            XCTAssertTrue(result.isSuccess)
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)
        
        XCTAssertEqual(count, 1)
    }
    
    func testOneLargeTask() {
        var count = 0
        let batcher = DynamicTaskBatcher(numberOfTasks: 1, taskCostEvaluator: { _ in 2.0 }) { range, finish in
            count += 1
            XCTAssertEqual(range, 0..<1)
            finish(.definitive(.success(())))
        }
        
        let expect = self.expectation(description: "executing")
        batcher.start { result in
            XCTAssertTrue(result.isSuccess)
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)
        
        XCTAssertEqual(count, 1)
    }
    
    func testTwoSmallTasks() {
        var count = 0
        let batcher = DynamicTaskBatcher(numberOfTasks: 2, taskCostEvaluator: { _ in 0.1 }) { range, finish in
            count += 1
            XCTAssertEqual(range, 0..<2)
            finish(.definitive(.success(())))
        }
        
        let expect = self.expectation(description: "executing")
        batcher.start { result in
            XCTAssertTrue(result.isSuccess)
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)
        
        XCTAssertEqual(count, 1)
    }
    
    func testTwoLargeTasks() {
        var count = 0
        let batcher = DynamicTaskBatcher(numberOfTasks: 2, taskCostEvaluator: { _ in 1.0 }) { range, finish in
            count += 1
            XCTAssertEqual(range.count, 1)
            finish(.definitive(.success(())))
        }
        
        let expect = self.expectation(description: "executing")
        batcher.start { result in
            XCTAssertTrue(result.isSuccess)
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)
        
        XCTAssertEqual(count, 2)
    }
    
    func testAccumulatingCost() {
        var count = 0
        let batcher = DynamicTaskBatcher(numberOfTasks: 4, taskCostEvaluator: { index in
            switch index {
            case 0, 1:
                return 0.5
            case 2:
                return 0.49
            case 3:
                return 0.02
            default:
                return 0.1
            }
        }) { range, finish in
            count += 1
            if range.lowerBound == 0 {
                XCTAssertEqual(range.count, 1)
            } else if range.lowerBound == 1 {
                XCTAssertEqual(range.count, 2)
            } else {
                XCTAssertEqual(range.count, 1)
            }
            finish(.definitive(.success(())))
        }
        
        let expect = self.expectation(description: "executing")
        batcher.start { result in
            XCTAssertTrue(result.isSuccess)
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)
        
        XCTAssertEqual(count, 3)
    }
    
    func testGrowingAndRepeatingBatchesUntilFail() {
        var count = 0
        let batcher = DynamicTaskBatcher(numberOfTasks: 2, taskCostEvaluator: { _ in 1.01 }) { range, finish in
            count += 1
            XCTAssertEqual(range.lowerBound, 0)
            finish(.growBatchAndReexecute)
        }
        
        let expect = self.expectation(description: "executing")
        batcher.start { result in
            XCTAssertFalse(result.isSuccess)
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)
        
        XCTAssertEqual(count, 2)
    }
    
    func testGrowingAndRepeatingBatchesWithSuccess() {
        var count = 0
        let batcher = DynamicTaskBatcher(numberOfTasks: 3, taskCostEvaluator: { _ in 1.01 }) { range, finish in
            count += 1
            switch range {
            case 0..<1:
                finish(.growBatchAndReexecute)
            case 0..<2:
                finish(.definitive(.success(())))
            case 2..<3:
                finish(.definitive(.success(())))
            default:
                XCTFail()
            }
        }
        
        let expect = self.expectation(description: "executing")
        batcher.start { result in
            XCTAssertTrue(result.isSuccess)
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)
        
        XCTAssertEqual(count, 3)
    }
    
    static var allTests = [
        ("testZeroTasks", testZeroTasks),
        ("testOneTask", testOneTask),
        ("testOneLargeTask", testOneLargeTask),
        ("testTwoSmallTasks", testTwoSmallTasks),
        ("testTwoLargeTasks", testTwoLargeTasks),
        ("testAccumulatingCost", testAccumulatingCost),
        ("testFailure", testFailure),
        ("testGrowingAndRepeatingBatchesUntilFail", testGrowingAndRepeatingBatchesUntilFail),
        ("testGrowingAndRepeatingBatchesWithSuccess", testGrowingAndRepeatingBatchesWithSuccess),
    ]
}
