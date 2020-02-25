//
//  AsynchronousOperation.swift
//  
//
//  Created by Drew McCormack on 25/02/2020.
//

import Foundation

open class AsynchronousOperation : Foundation.Operation {
    
    /// You can set this instead of subclassing and overriding `begin`, in order to perform a task.
    /// You need to make sure that `end` gets called when the task is complete.
    /// The block will be released upon completion, to break potential retain cycles.
    public var beginBlock: (() -> Void)?
    
    /// You can set this to perform after the task has ended.
    /// The block will be released upon completion, to break potential retain cycles.
    /// - Important: Only guaranteed to be called if the operation is started (i.e. `begin()` has been called). If cancelled before this stage the block is not called.
    public var endBlock: (() -> Void)?
    
    private var _isFinished: Bool = false
    override open private(set) var isFinished: Bool {
        get {
            return _isFinished
        }
        set {
            _isFinished = newValue
        }
    }
    
    private var _isExecuting: Bool = false
    override open private(set) var isExecuting: Bool {
        get {
            return _isExecuting
        }
        set {
            _isExecuting = newValue
        }
    }

    override open var isAsynchronous: Bool {
        return true
    }
    
    override open func start() {
        fireNotificationsForBeginning()
        begin()
    }
    
    /// Override to begin an asynchronous task. The overriding code should not chain
    /// to `super`, but it must call `end` when it is done.
    /// If this method is not overridden, it will execute the `beginBlock`, or, if that
    /// is `nil`, it will execute `main` and then `end`, mimicking a synchronous operation.
    open func begin() {
        if let block = beginBlock {
            // Block is set, so execute that. `end` will be called in block.
            block()
        } else {
            // Assume synchronous. Run `main` and call `end`.
            main()
            end()
        }
    }

    /// Call this method to indicate that the asynchronous task is complete.
    open func end() {
        guard !self.isFinished else { return }

        endBlock?()
        
        // Break any retain cycles
        endBlock = nil
        beginBlock = nil
        
        fireNotificationsForFinishing()
    }
    
    /// Fires the KVO needed for the operation queue to know the operation has begun
    private func fireNotificationsForBeginning() {
        willChangeValue(forKey: "isFinished")
        willChangeValue(forKey: "isExecuting")
        self.isFinished = false
        self.isExecuting = true
        didChangeValue(forKey: "isExecuting")
        didChangeValue(forKey: "isFinished")
    }
    
    /// Fires the KVO needed for the operation queue to know operation has finished
    private func fireNotificationsForFinishing() {
        willChangeValue(forKey: "isFinished")
        willChangeValue(forKey: "isExecuting")
        self.isFinished = true
        self.isExecuting = false
        didChangeValue(forKey: "isExecuting")
        didChangeValue(forKey: "isFinished")
    }
}

extension OperationQueue {
    
    /// Enqueues an asynchronous operation for the block passed. The block has to manually call
    /// the function that it receives to indicate it is complete.
    public func addAsynchronousOperation(_ block: @escaping (@escaping (()->Void))->Void) {
        let operation = AsynchronousOperation()
        operation.beginBlock = { [unowned operation] in
            block(operation.end)
        }
        addOperation(operation)
    }
    
}
