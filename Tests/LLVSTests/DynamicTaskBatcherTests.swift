//
//  DynamicTaskBatcherTests.swift
//
//
//  Created by Drew McCormack on 06/03/2020.
//

import Foundation

import Testing
import Foundation
@testable import LLVS

@Suite struct DynamicTaskBatcherTests {

    enum TestError: Swift.Error {
        case testError
    }

    @Test func failure() async throws {
        let counter = Counter()
        let batcher = DynamicTaskBatcher(numberOfTasks: 10, taskCostEvaluator: { _ in 0.1 }) { range in
            counter.increment()
            return .definitive(.failure(TestError.testError))
        }

        do {
            try await batcher.start()
            Issue.record("Should have thrown")
        } catch {
            // Expected
        }
        #expect(counter.value == 1)
    }

    @Test func zeroTasks() async throws {
        let batcher = DynamicTaskBatcher(numberOfTasks: 0, taskCostEvaluator: { _ in 0.1 }) { _ in
            return .definitive(.success(()))
        }
        try await batcher.start()
    }

    @Test func oneTask() async throws {
        let counter = Counter()
        let batcher = DynamicTaskBatcher(numberOfTasks: 1, taskCostEvaluator: { _ in 0.1 }) { range in
            counter.increment()
            #expect(range == 0..<1)
            return .definitive(.success(()))
        }

        try await batcher.start()
        #expect(counter.value == 1)
    }

    @Test func oneLargeTask() async throws {
        let counter = Counter()
        let batcher = DynamicTaskBatcher(numberOfTasks: 1, taskCostEvaluator: { _ in 2.0 }) { range in
            counter.increment()
            #expect(range == 0..<1)
            return .definitive(.success(()))
        }

        try await batcher.start()
        #expect(counter.value == 1)
    }

    @Test func twoSmallTasks() async throws {
        let counter = Counter()
        let batcher = DynamicTaskBatcher(numberOfTasks: 2, taskCostEvaluator: { _ in 0.1 }) { range in
            counter.increment()
            #expect(range == 0..<2)
            return .definitive(.success(()))
        }

        try await batcher.start()
        #expect(counter.value == 1)
    }

    @Test func twoLargeTasks() async throws {
        let counter = Counter()
        let batcher = DynamicTaskBatcher(numberOfTasks: 2, taskCostEvaluator: { _ in 1.0 }) { range in
            counter.increment()
            #expect(range.count == 1)
            return .definitive(.success(()))
        }

        try await batcher.start()
        #expect(counter.value == 2)
    }

    @Test func accumulatingCost() async throws {
        let counter = Counter()
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
            counter.increment()
            if range.lowerBound == 0 {
                #expect(range.count == 1)
            } else if range.lowerBound == 1 {
                #expect(range.count == 2)
            } else {
                #expect(range.count == 1)
            }
            return .definitive(.success(()))
        }

        try await batcher.start()
        #expect(counter.value == 3)
    }

    @Test func growingAndRepeatingBatchesUntilFail() async throws {
        let counter = Counter()
        let batcher = DynamicTaskBatcher(numberOfTasks: 2, taskCostEvaluator: { _ in 1.01 }) { range in
            counter.increment()
            #expect(range.lowerBound == 0)
            return .growBatchAndReexecute
        }

        do {
            try await batcher.start()
            Issue.record("Should have thrown")
        } catch {
            // Expected
        }
        #expect(counter.value == 2)
    }

    @Test func growingAndRepeatingBatchesWithSuccess() async throws {
        let counter = Counter()
        let batcher = DynamicTaskBatcher(numberOfTasks: 3, taskCostEvaluator: { _ in 1.01 }) { range in
            counter.increment()
            switch range {
            case 0..<1:
                return .growBatchAndReexecute
            case 0..<2:
                return .definitive(.success(()))
            case 2..<3:
                return .definitive(.success(()))
            default:
                Issue.record()
                return .definitive(.failure(TestError.testError))
            }
        }

        try await batcher.start()
        #expect(counter.value == 3)
    }
}

/// The batcher can call its closure from more than one task, so the test counts under a lock.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
