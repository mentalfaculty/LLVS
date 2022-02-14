//
//  Database.swift
//  LLVS
//
//  Created by Drew McCormack on 19/01/2017.
//

import Foundation
import SQLite3

// Used for SQLite cleanup
internal let SQLITE_STATIC = unsafeBitCast(0, to: sqlite3_destructor_type.self)
internal let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin wrapper around SQLite3. Allows creating, updating, and querying a SQLite3 database
/// with as little fuss as possible.
/// This class is not thread-safe. It is up to the
/// user of the class to ensure it is only accessed from one thread at a time (e.g. using
/// a serial queue). The decision not to use an internal queue is deliberate:
/// this gives the caller complete freedom in how the database is accessed, rather than
/// imposing a particular solution (e.g. GCD, OperationQueue, Actor). It keeps database 
/// access independent of the preferred concurrency model used in the app.
public final class SQLiteDatabase {

    /// SQLite Errors
    public enum Error: Swift.Error {
        case openFailed(code: Int32)
        case closeFailed(code: Int32)
        case statementFailed(statement: String, code: Int32)
        case bindingFailed(bindingIndex: Int, value: Any?, code: Int32)
        case queryFailed(query: String, code: Int32)
    }
    
    /// Location of the database file
    public let fileURL: URL
    
    /// Pointer to the SQLite database object
    private var database: OpaquePointer!
    
    /// The last error message from the database
    public var errorMessage: String? {
        return String(cString: sqlite3_errmsg(database))
    }
    
    
    // MARK: Creating and Deleting
    
    /// Open or create a database at the file URL passed in
    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        
        var newDatabase: OpaquePointer?
        let code = sqlite3_open(fileURL.path, &newDatabase)
        guard code == SQLITE_OK else {
            throw Error.openFailed(code: code)
        }
        database = newDatabase!
    }
    
    deinit {
        do {
            try close()
        } catch {
            print("Could not close database: \(error)")
        }
    }
    
    
    // MARK: Executing SQL
    
    /// Explicitly close the database. If you don't call this, it will be called in deinit.
    public func close() throws {
        guard let database = database else { return }
        let code = sqlite3_close(database)
        if code != SQLITE_OK {
            throw Error.closeFailed(code: code)
        }
        self.database = nil
    }
    
    /// Execute a SQLite statement with bindings provided by an array of arrays. 
    /// Each entry in the outer array is an array holding the bindings for one statement.
    /// The statement will be executed multiple times with different values.
    /// Passing nothing for the bindings can be used to execute a statement that has no bound values.
    /// Passing an empty array for the bindings is allowed, but is effectively a no-op.
    public func execute(statement: String, withBindingsList bindings: [[Any?]] = [[]]) throws {
        var sqlStatement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(database, statement, -1, &sqlStatement, nil)
        guard prepareCode == SQLITE_OK else {
            throw Error.statementFailed(statement: statement, code: prepareCode)
        }
        
        defer {
            finalize(sqlStatement!)
        }
    
        for boundValues in bindings {
            try bind(values: boundValues, toSQLStatement: sqlStatement!)
            
            let stepCode = sqlite3_step(sqlStatement)
            guard  stepCode == SQLITE_DONE else {
                throw Error.statementFailed(statement: statement, code: stepCode)
            }
            
            let resetCode = sqlite3_reset(sqlStatement)
            guard resetCode == SQLITE_OK else {
                throw Error.statementFailed(statement: statement, code: resetCode)
            }
        }
    }
    
    /// Fetch with a query, and iterate the results in the row handler.
    /// The row should not be allowed to escape the row handler block, and must remain on the same thread.
    /// In general, you should extract the data from the `Row` directly, and once that is done, you can treat
    /// the resulting data as you please.
    public func forEach(matchingQuery query: String, withBindings bindings: [Any?] = [], rowHandler: (Row) throws ->Void ) throws {
        var sqlStatement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(database, query, -1, &sqlStatement, nil)
        guard prepareCode == SQLITE_OK else {
            throw Error.queryFailed(query: query, code: prepareCode)
        }
        
        defer {
            finalize(sqlStatement!)
        }
        
        try bind(values: bindings, toSQLStatement: sqlStatement!)
        
        while sqlite3_step(sqlStatement) == SQLITE_ROW {
            let row = Row(statement: sqlStatement!)
            try rowHandler(row)
        }
    }
    
    /// Finalizes the statement. This func does not throw, because it is often called
    /// in a defer block, where errors go unhandled.
    private func finalize(_ sqlStatement: OpaquePointer) {
        let finalizeCode = sqlite3_finalize(sqlStatement)
        if finalizeCode != SQLITE_OK {
            print("Failed to finalize statement")
        }
    }
    
    /// Binds the passed values to the corresponding placeholders in the compiled SQL statement.
    private func bind(values: [Any?], toSQLStatement sqlStatement: OpaquePointer) throws {
        for (i, value) in values.enumerated() {
            let bindIndex = Int32(i + 1)
            var code = SQLITE_OK
            switch value {
            case nil:
                code = sqlite3_bind_null(sqlStatement, bindIndex)
            case let text? as String?:
                let utf8String = text.cString(using: .utf8)
                code = sqlite3_bind_text(sqlStatement, bindIndex, utf8String, -1, SQLITE_TRANSIENT)
            case let data? as Data?:
                let bytes = [UInt8](data)
                code = sqlite3_bind_blob(sqlStatement, bindIndex, bytes, Int32(data.count), SQLITE_TRANSIENT)
            case let intValue? as Int32?:
                code = sqlite3_bind_int(sqlStatement, bindIndex, intValue)
            case let intValue? as Int64?:
                code = sqlite3_bind_int64(sqlStatement, bindIndex, intValue)
            case let doubleValue? as Double?:
                code = sqlite3_bind_double(sqlStatement, bindIndex, doubleValue)
            default:
                preconditionFailure("Invalid type")
            }
            
            guard code == SQLITE_OK else {
                throw Error.bindingFailed(bindingIndex: i+1, value: value, code: code)
            }
        }
    }
    
    
    // MARK: Row

    /// Row struct used in fetches
    public struct Row {
        
        private let statement: OpaquePointer
        
        fileprivate init(statement: OpaquePointer) {
            self.statement = statement
        }
        
        /// Retrieve a value from the database, in the column passed.
        /// Only SQLite types are supported (Int32, Int64, Double, String, Data),
        /// as well as optional variants. Column indexes are zero based.
        public func value<T>(inColumnAtIndex column: Int) -> T? {
            if sqlite3_column_type(statement, 0) == SQLITE_NULL {
                return nil
            }
            
            switch T.self {
            case is String.Type:
                let cString = sqlite3_column_text(statement, Int32(column))
                return String(cString: cString!) as? T
            case is Data.Type:
                let length = sqlite3_column_bytes(statement, Int32(column))
                let bytes = sqlite3_column_blob(statement, Int32(column))
                let data = Data(bytes: bytes!, count: Int(length))
                return data as? T
            case is Int64.Type:
                return sqlite3_column_int64(statement, Int32(column)) as? T
            case is Int32.Type:
                return Int32(sqlite3_column_int(statement, Int32(column))) as? T
            case is Double.Type:
                return sqlite3_column_double(statement, Int32(column)) as? T
            default:
                preconditionFailure("Unsupported type")
            }
        }

    }

}

