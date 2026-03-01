//
//  DynamicTaskBatcherTests.swift
//
//
//  Created by Drew McCormack on 06/03/2020.
//

import Foundation
import Testing
@testable import LLVS

@Suite struct DynamicTaskBatcherTests {

    enum TestError: Swift.Error {
        case testError
    }

    @Test func failure() async throws {
        var count = 0
        let batcher = DynamicTaskBatcher(numberOfTasks: 10, taskCostEvaluator: { _ in 0.1 }) { range in
            count += 1
            throw TestError.testError
        }

        do {
            try await batcher.start()
            Issue.record("Should have thrown")
        } catch {
            // Expected
        }
        #expect(count == 1)
    }

    @Test func zeroTasks() async throws {
        let batcher = DynamicTaskBatcher(numberOfTasks: 0, taskCostEvaluator: { _ in 0.1 }) { _ in
            return .completed
        }
        try await batcher.start()
    }

    @Test func oneTask() async throws {
        var count = 0
        let batcher = DynamicTaskBatcher(numberOfTasks: 1, taskCostEvaluator: { _ in 0.1 }) { range in
            count += 1
            #expect(range == 0..<1)
            return .completed
        }

        try await batcher.start()
        #expect(count == 1)
    }

    @Test func oneLargeTask() async throws {
        var count = 0
        let batcher = DynamicTaskBatcher(numberOfTasks: 1, taskCostEvaluator: { _ in 2.0 }) { range in
            count += 1
            #expect(range == 0..<1)
            return .completed
        }

        try await batcher.start()
        #expect(count == 1)
    }

    @Test func twoSmallTasks() async throws {
        var count = 0
        let batcher = DynamicTaskBatcher(numberOfTasks: 2, taskCostEvaluator: { _ in 0.1 }) { range in
            count += 1
            #expect(range == 0..<2)
            return .completed
        }

        try await batcher.start()
        #expect(count == 1)
    }

    @Test func twoLargeTasks() async throws {
        var count = 0
        let batcher = DynamicTaskBatcher(numberOfTasks: 2, taskCostEvaluator: { _ in 1.0 }) { range in
            count += 1
            #expect(range.count == 1)
            return .completed
        }

        try await batcher.start()
        #expect(count == 2)
    }

    @Test func accumulatingCost() async throws {
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
                #expect(range.count == 1)
            } else if range.lowerBound == 1 {
                #expect(range.count == 2)
            } else {
                #expect(range.count == 1)
            }
            return .completed
        }

        try await batcher.start()
        #expect(count == 3)
    }

    @Test func growingAndRepeatingBatchesUntilFail() async throws {
        var count = 0
        let batcher = DynamicTaskBatcher(numberOfTasks: 2, taskCostEvaluator: { _ in 1.01 }) { range in
            count += 1
            #expect(range.lowerBound == 0)
            return .growBatchAndRetry
        }

        do {
            try await batcher.start()
            Issue.record("Should have thrown")
        } catch {
            // Expected
        }
        #expect(count == 2)
    }

    @Test func growingAndRepeatingBatchesWithSuccess() async throws {
        var count = 0
        let batcher = DynamicTaskBatcher(numberOfTasks: 3, taskCostEvaluator: { _ in 1.01 }) { range in
            count += 1
            switch range {
            case 0..<1:
                return .growBatchAndRetry
            case 0..<2:
                return .completed
            case 2..<3:
                return .completed
            default:
                Issue.record()
                return .completed
            }
        }

        try await batcher.start()
        #expect(count == 3)
    }
}
