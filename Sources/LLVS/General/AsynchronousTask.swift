//
//  AsynchronousTask.swift
//  LLVS
//
//  Created by Drew McCormack on 04/03/2019.
//

import Dispatch

/// An asynchronous task. Chaining this can avoid deep nesting.
public class AsynchronousTask {
    
    public typealias Callback = (Result<Void, Error>)->Void
    
    public private(set) var result: Result<Void, Error>? {
        didSet {
            guard let result = result else { fatalError("Result shoudl never be set back to nil") }
            
            // This block is used to capture self (and next).
            // Othersize pre-mature release happens on failure.
            // It is asynchronous to prevent deadlocks.
            DispatchQueue.global(qos: .default).async {
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
    public var completionBlock: ((Result<Void, Error>)->Void)?
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
            let existingLastCompletion = last.completionBlock
            last.completionBlock = { result in
                existingLastCompletion?(result)
                completionHandler(result)
            }
            first.execute()
        } else {
            completionHandler(.success(()))
        }
    }
    
}

