//
//  Log.swift
//  LLVS
//
//  Created by Drew McCormack on 10/05/19.
//

import Foundation
import os

public let log = Log()

public class Log {

    public enum Level : Int, Comparable {
        case none
        case error
        case warning
        case trace
        case verbose

        public var stringValue: String {
            switch self {
            case .none:
                return "N"
            case .error:
                return "E"
            case .warning:
                return "W"
            case .trace:
                return "T"
            case .verbose:
                return "V"
            }
        }
    }

    public var level = Level.none

    @inline(__always) public final func verbose(_ messageClosure: @autoclosure () -> String, path: StaticString = #file, function: StaticString = #function, line: Int = #line) {
        if level >= .verbose {
            Log.append(messageClosure(), level: .verbose, path: path, function: function, line: line)
        }
    }

    @inline(__always) public final func trace(_ messageClosure: @autoclosure () -> String, path: StaticString = #file, function: StaticString = #function, line: Int = #line) {
        if level >= .trace {
            Log.append(messageClosure(), level: .trace, path: path, function: function, line: line)
        }
    }

    @inline(__always) public final func warning(_ messageClosure: @autoclosure () -> String, path: StaticString = #file, function: StaticString = #function, line: Int = #line) {
        if level >= .warning {
            Log.append(messageClosure(), level: .warning, path: path, function: function, line: line)
        }
    }

    @inline(__always) public final func error(_ messageClosure: @autoclosure () -> String, path: StaticString = #file, function: StaticString = #function, line: Int = #line) {
        if level >= .error {
            Log.append(messageClosure(), level: .error, path: path, function: function, line: line)
        }
    }

    @inline(__always) public final class func append(_ messageClosure: @autoclosure () -> String, level: Level, path: StaticString, function: StaticString, line: Int = #line) {
        let filename = (String(describing: path) as NSString).lastPathComponent
        let text = "\(level.rawValue) \(filename)(\(line)) : \(function) : \(messageClosure())"
        os_log("%{public}@", text)
    }
}

@inline(__always) public func <(a: Log.Level, b: Log.Level) -> Bool {
    return a.rawValue < b.rawValue
}
