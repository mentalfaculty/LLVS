//
//  DynamicTaskBatcher.swift
//
//
//  Created by Drew McCormack on 06/03/2020.
//

import Foundation

/// Generates batches for a fixed number of asynchronous tasks, based on a cost criterion for each task.
/// This is useful for asynchronously processing an array of tasks, where you have a cost function for each task, and want batches that try to avoid having too much cost.
/// It can also dynamically adjust if a batch is not suitable, by growing and repeating the batch.
public final class DynamicTaskBatcher {

    public enum Error: Swift.Error {
        case couldNotFurtherGrowFailingBatch
    }

    /// The outcome of a single batch execution.
    public enum BatchOutcome {
        case completed
        case growBatchAndRetry
    }

    public typealias TaskCostEvaluator = (_ index: Int) -> Float
    public typealias BatchExecuter = (_ batchIndexRange: Range<Int>) async throws -> BatchOutcome

    public let numberOfTasks: Int

    /// Func that estimates the cost of a given task. Cost is between 0 and 1.
    /// A cost of 1 will result in a batch with only that one task. Task costs are tallied until
    /// they exceed 1, at which point the batch is complete and run.
    public let taskCostEvaluator: TaskCostEvaluator

    /// Executes a batch
    public let batchExecuter: BatchExecuter

    public init(numberOfTasks: Int, taskCostEvaluator: @escaping TaskCostEvaluator, batchExecuter: @escaping BatchExecuter) {
        self.numberOfTasks = numberOfTasks
        self.taskCostEvaluator = taskCostEvaluator
        self.batchExecuter = batchExecuter
    }

    // MARK: Execution

    private var currentBatchSize: Int = -1
    private var completedCount: Int = 0
    private var previousBatchNeedsReexecutionAfterGrowth = false

    public func start() async throws {
        currentBatchSize = -1
        completedCount = 0
        previousBatchNeedsReexecutionAfterGrowth = false

        while completedCount < numberOfTasks {
            if previousBatchNeedsReexecutionAfterGrowth, completedCount + currentBatchSize == numberOfTasks {
                throw Error.couldNotFurtherGrowFailingBatch
            }

            currentBatchSize = calculateNextBatchSize()

            let outcome = try await batchExecuter(completedCount..<completedCount + currentBatchSize)
            switch outcome {
            case .completed:
                completedCount += currentBatchSize
            case .growBatchAndRetry:
                previousBatchNeedsReexecutionAfterGrowth = true
            }
        }
    }

    private func calculateNextBatchSize() -> Int {
        let numberRemaining = numberOfTasks - completedCount
        defer { previousBatchNeedsReexecutionAfterGrowth = false }

        guard completedCount < numberOfTasks else { return 0 }
        guard !previousBatchNeedsReexecutionAfterGrowth else {
            return min(currentBatchSize + 1, numberRemaining)
        }

        // Increase index until the accumulated cost is greater than 1
        var i = completedCount
        var cost: Float = 0
        while i < numberOfTasks {
            cost += taskCostEvaluator(i)
            if cost >= 1.0 { break }
            i += 1
        }

        let newBatchSize = max(1, i - completedCount)
        return min(newBatchSize, numberRemaining)
    }
}
