//
//  OwnedTableApply.swift
//  LLVS
//
//  Created by Drew McCormack on 21/09/2026.
//

import Foundation
import LLVS
import LLVSModel
import LLVSSQLite

extension OwnedTable {

    /// Writes changes from LLVS into the table, without recording them as local edits.
    ///
    /// Returns how many rows were written or deleted. A value that is not a JSON object is
    /// skipped rather than throwing, because one value this build cannot read must not stop
    /// the rest — the same rule the read-only projection follows.
    @discardableResult
    public func apply(_ changes: [Value.Change], in database: SQLiteDatabase) throws -> Int {
        var applied = 0
        try whileApplyingRemoteChanges(in: database) {
            try database.inTransaction {
                for change in changes {
                    switch change {
                    case let .insert(value), let .update(value):
                        guard let object = try? JSONSerialization.jsonObject(with: value.data) as? [String: Any] else {
                            continue
                        }
                        try self.upsert(object, id: value.id, in: database)
                        applied += 1
                    case let .remove(valueId):
                        try database.execute(
                            statement: "DELETE FROM \(self.tableName) WHERE llvs_id = ?",
                            withBindingsList: [[valueId.rawValue]])
                        applied += 1
                    case .preserve, .preserveRemoval:
                        // The value was carried through a merge unchanged, so the row already
                        // holds what it should.
                        continue
                    }
                }
            }
        }
        return applied
    }

    private func upsert(_ object: [String: Any], id: Value.ID, in database: SQLiteDatabase) throws {
        let columnNames = ["llvs_id"] + schema.columns.map(\.columnName)
        let placeholders = Array(repeating: "?", count: columnNames.count).joined(separator: ", ")
        let bindings: [Any?] = [id.rawValue] + schema.columns.map { binding(for: object[$0.propertyName], column: $0) }

        // A table with nothing but the identifier has no SET clause to write, and SQLite
        // rejects an empty one.
        let conflictClause: String
        if schema.columns.isEmpty {
            conflictClause = "ON CONFLICT(llvs_id) DO NOTHING"
        } else {
            let assignments = schema.columns.map { "\($0.columnName) = excluded.\($0.columnName)" }.joined(separator: ", ")
            conflictClause = "ON CONFLICT(llvs_id) DO UPDATE SET \(assignments)"
        }

        try database.execute(
            statement: """
                INSERT INTO \(tableName) (\(columnNames.joined(separator: ", "))) VALUES (\(placeholders))
                \(conflictClause)
                """,
            withBindingsList: [bindings])
    }

    /// A property the value does not carry binds as NULL, so a model that has gained a
    /// property reads back with that column empty rather than failing to apply at all.
    ///
    /// A `Bool` arrives from `JSONSerialization` as an `NSNumber`, so it binds through the
    /// `INTEGER` case as 0 or 1 with no special handling.
    private func binding(for propertyValue: Any?, column: ModelColumn) -> Any? {
        guard let propertyValue, !(propertyValue is NSNull) else { return nil }

        // Switching on the storage case, not the SQLite type: Int, Bool and Date are all
        // INTEGER and each converts differently on the way in as well as out.
        switch column.storage {
        case .text, .uuid:
            return propertyValue as? String
        case .integer:
            return (propertyValue as? NSNumber)?.int64Value
        case .real:
            return (propertyValue as? NSNumber)?.doubleValue
        case .boolean:
            // JSONSerialization gives a Bool as an NSNumber, so read it as one and store 0/1.
            guard let number = propertyValue as? NSNumber else { return nil }
            return number.boolValue ? Int64(1) : Int64(0)
        case .date:
            // Codable gives seconds since 2001; the column holds Unix seconds, so that
            // strftime('%s', 'now') and every other SQLite tool mean what they say.
            guard let referenceSeconds = (propertyValue as? NSNumber)?.doubleValue else { return nil }
            return Int64(Date(timeIntervalSinceReferenceDate: referenceSeconds).timeIntervalSince1970)
        case .blob:
            // Codable encodes Data as base64, which is what the stored JSON carries.
            return (propertyValue as? String).flatMap { Data(base64Encoded: $0) }
        case .json:
            guard let data = try? JSONSerialization.data(withJSONObject: propertyValue, options: [.sortedKeys]) else {
                return nil
            }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
