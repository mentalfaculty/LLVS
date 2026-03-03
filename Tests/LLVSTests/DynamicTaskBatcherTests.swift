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

    func testFailure() async throws {
        var count = 0
        let batcher = DynamicTaskBatcher(numberOfTasks: 10, taskCostEvaluator: { _ in 0.1 }) { range in
            count += 1
            return .definitive(.failure(TestError.testError))
        }

        do {
            try await batcher.start()
            XCTFail("Should have thrown")
        } catch {
            // Expected
        }
        XCTAssertEqual(count, 1)
    }

    func testZeroTasks() async throws {
        let batcher = DynamicTaskBatcher(numberOfTasks: 0, taskCostEvaluator: { _ in 0.1 }) { _ in
            return .definitive(.success(()))
        }
        try await batcher.start()
    }

    func testOneTask() async throws {
        var count = 0
        let batcher = DynamicTaskBatcher(numberOfTasks: 1, taskCostEvaluator: { _ in 0.1 }) { range in
            count += 1
            XCTAssertEqual(range, 0..<1)
            return .definitive(.success(()))
        }

        try await batcher.start()
        XCTAssertEqual(count, 1)
    }

    func testOneLargeTask() async throws {
        var count = 0
        let batcher = DynamicTaskBatcher(numberOfTasks: 1, taskCostEvaluator: { _ in 2.0 }) { range in
            count += 1
            XCTAssertEqual(range, 0..<1)
            return .definitive(.success(()))
        }

        try await batcher.start()
        XCTAssertEqual(count, 1)
    }

    func testTwoSmallTasks() async throws {
        var count = 0
        let batcher = DynamicTaskBatcher(numberOfTasks: 2, taskCostEvaluator: { _ in 0.1 }) { range in
            count += 1
            XCTAssertEqual(range, 0..<2)
            return .definitive(.success(()))
        }

        try await batcher.start()
        XCTAssertEqual(count, 1)
    }

    func testTwoLargeTasks() async throws {
        var count = 0
        let batcher = DynamicTaskBatcher(numberOfTasks: 2, taskCostEvaluator: { _ in 1.0 }) { range in
            count += 1
            XCTAssertEqual(range.count, 1)
            return .definitive(.success(()))
        }

        try await batcher.start()
        XCTAssertEqual(count, 2)
    }

    func testAccumulatingCost() async throws {
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
        }) { range in
            count += 1
            if range.lowerBound == 0 {
                XCTAssertEqual(range.count, 1)
            } else if range.lowerBound == 1 {
                XCTAssertEqual(range.count, 2)
            } else {
                XCTAssertEqual(range.count, 1)
            }
            return .definitive(.success(()))
        }

        try await batcher.start()
        XCTAssertEqual(count, 3)
    }

    func testGrowingAndRepeatingBatchesUntilFail() async throws {
        var count = 0
        let batcher = DynamicTaskBatcher(numberOfTasks: 2, taskCostEvaluator: { _ in 1.01 }) { range in
            count += 1
            XCTAssertEqual(range.lowerBound, 0)
            return .growBatchAndReexecute
        }

        do {
            try await batcher.start()
            XCTFail("Should have thrown")
        } catch {
            // Expected
        }
        XCTAssertEqual(count, 2)
    }

    func testGrowingAndRepeatingBatchesWithSuccess() async throws {
        var count = 0
        let batcher = DynamicTaskBatcher(numberOfTasks: 3, taskCostEvaluator: { _ in 1.01 }) { range in
            count += 1
            switch range {
            case 0..<1:
                return .growBatchAndReexecute
            case 0..<2:
                return .definitive(.success(()))
            case 2..<3:
                return .definitive(.success(()))
            default:
                XCTFail()
                return .definitive(.failure(TestError.testError))
            }
        }

        try await batcher.start()
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
