//
//  AsynchronousTask.swift
//  LLVS
//
//  Created by Drew McCormack on 04/03/2019.
//
import Dispatch

/// An asynchronous task. Chaining this can avoid deep nesting.
public class AsynchronousTask {
    
    public enum Result {
        case success
        case failure(Error)
        
        public var success: Bool {
            if case .success = self {
                return true
            } else {
                return false
            }
        }
    }
    
    public typealias Callback = (Result)->Void
    
    public private(set) var result: Result? {
        didSet {
            guard let result = result else { fatalError("Result shoudl never be set back to nil") }
            
            // This block is used to capture self (and next).
            // Othersize pre-mature release happens on failure.
            // It is asynchronous to prevent deadlocks.
            DispatchQueue.global(qos: .utility).async {
                self.completionBlock?(result)
                switch result {
                case .failure:
                    self.next?.result = result
                case .success:
                    self.next?.execute()
                }
            }
        }
    }
    
    public let executionBlock: (_ finish: @escaping Callback)->Void
    public var completionBlock: ((Result)->Void)?
    public var next: AsynchronousTask?
    
    public init(_ block: @escaping (_ finish: @escaping Callback)->Void) {
        self.executionBlock = block
    }
    
    public func execute() {
        executionBlock { result in
            self.result = result
        }
    }
}

public extension Array where Element == AsynchronousTask {
    
    func chain() {
        zip(self, self.dropFirst()).forEach { $0.0.next = $0.1 }
    }
    
    func executeInOrder(completingWith completionHandler: @escaping AsynchronousTask.Callback) {
        chain()
        if let first = first, let last = last {
            last.completionBlock = completionHandler
            first.execute()
        } else {
            completionHandler(.success)
        }
    }
    
}

public extension Result {
    
    var taskResult: AsynchronousTask.Result {
        switch self {
        case .failure(let error):
            return .failure(error)
        case .success:
            return .success
        }
    }
    
}
