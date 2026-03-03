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
    public enum BatchCompletionOutcome {
        /// Definitively succeeded or failed. Failure causes completion block to be called with error
        case definitive(Result<Void, Swift.Error>)

        /// A half failure. Use this to indicate the batch did not succeed, but should be retried after growing.
        /// If it is not possible to grow the batch further, completion is called with error.
        case growBatchAndReexecute
    }

    public typealias TaskCostEvaluator = (_ index: Int) -> Float
    public typealias BatchExecuter = @Sendable (_ batchIndexRange: Range<Int>) async throws -> BatchCompletionOutcome

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
        self.currentBatchSize = -1
        self.completedCount = 0
        self.previousBatchNeedsReexecutionAfterGrowth = false
        try await startNextBatch()
    }

    private func calculateNextBatchSize() -> Int {
        let numberRemaining = numberOfTasks-completedCount
        defer { previousBatchNeedsReexecutionAfterGrowth = false }

        guard completedCount < numberOfTasks else { return 0 }
        guard !previousBatchNeedsReexecutionAfterGrowth else {
            return min(currentBatchSize+1, numberRemaining)
        }

        // Increase index until the accumulated cost is greater than 1
        var i = completedCount
        var cost: Float = 0
        while i < numberOfTasks {
            cost += taskCostEvaluator(i)
            if cost >= 1.0 { break }
            i += 1
        }

        let newBatchSize = max(1, i-completedCount)
        return min(newBatchSize, numberRemaining)
    }

    private func startNextBatch() async throws {
        let numberRemaining = numberOfTasks-completedCount

        guard numberRemaining > 0 else {
            return
        }

        if previousBatchNeedsReexecutionAfterGrowth, completedCount + currentBatchSize == numberOfTasks  {
            // Can't grow the batch anymore, and it is still failing. So fail outright
            throw Error.couldNotFurtherGrowFailingBatch
        }

        currentBatchSize = calculateNextBatchSize()

        let outcome = try await batchExecuter(completedCount..<completedCount+currentBatchSize)
        switch outcome {
        case .definitive(let result):
            switch result {
            case .success:
                self.completedCount += self.currentBatchSize
                try await self.startNextBatch()
            case .failure(let error):
                throw error
            }
        case .growBatchAndReexecute:
            self.previousBatchNeedsReexecutionAfterGrowth = true
            try await self.startNextBatch()
        }
    }

}
