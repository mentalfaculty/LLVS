//
//  OwnedTableDrain.swift
//  LLVS
//
//  Created by Drew McCormack on 21/09/2026.
//

import Foundation
import LLVS
import LLVSModel
import LLVSSQLite

/// What one drain did.
public struct DrainResult: Sendable {
    /// The version the captured changes became, or nil when there was nothing to say.
    public let version: Version.ID?
    public let changeCount: Int
}

extension OwnedTable {

    /// Turns everything captured so far into one LLVS version, based on `predecessor`.
    ///
    /// Several edits to one row become one change carrying the row as it now stands. The
    /// changelog says which rows and columns were touched; the row itself says what they
    /// now hold. Per-column capture earns its keep in the merge, not here.
    ///
    /// The changelog is read, turned into a version, and only then cleared — and only up to
    /// the sequence that was read, so a write arriving mid-drain survives for the next one.
    @discardableResult
    public func drain(in database: SQLiteDatabase, store: Store, basedOn predecessor: Version.ID?) throws -> DrainResult {
        let entries = try changelogEntries(in: database)
        guard let highestSequence = entries.last?.sequence else {
            return DrainResult(version: nil, changeCount: 0)
        }

        // One operation per row, latest wins: a row edited three times needs saying once.
        var operationsByValueId: [Value.ID: ChangelogEntry.Operation] = [:]
        for entry in entries {
            operationsByValueId[entry.valueId] = entry.operation
        }

        var changes: [Value.Change] = []
        for (valueId, operation) in operationsByValueId {
            let existedBefore = try predecessor.flatMap { try store.valueReference(id: valueId, at: $0) } != nil

            switch operation {
            case .insert, .update:
                guard let data = try rowData(for: valueId, in: database) else {
                    // Inserted and deleted again before this drain. Nothing was ever stored,
                    // so there is nothing to remove either.
                    continue
                }
                let value = Value(id: valueId, data: data)
                changes.append(existedBefore ? .update(value) : .insert(value))
            case .remove:
                // Removing something the store never held would fail, and says nothing.
                if existedBefore { changes.append(.remove(valueId)) }
            }
        }

        guard !changes.isEmpty else {
            try clearChangelog(in: database, throughSequence: highestSequence)
            return DrainResult(version: nil, changeCount: 0)
        }

        let version = try store.makeVersion(basedOnPredecessor: predecessor, storing: changes)
        try clearChangelog(in: database, throughSequence: highestSequence)
        return DrainResult(version: version.id, changeCount: changes.count)
    }

    /// The row as JSON, keyed by property name, or nil when the row is no longer there.
    ///
    /// The column name stops at the table: what LLVS stores must be what the model decodes
    /// from. A null column is left out rather than written as JSON null, so an optional
    /// property decodes as nil and a non-optional one fails loudly instead of silently.
    private func rowData(for valueId: Value.ID, in database: SQLiteDatabase) throws -> Data? {
        guard !schema.columns.isEmpty else {
            var found = false
            try database.forEach(matchingQuery: "SELECT llvs_id FROM \(tableName) WHERE llvs_id = ?",
                withBindings: [valueId.rawValue]) { _ in found = true }
            return found ? try JSONSerialization.data(withJSONObject: [String: Any]()) : nil
        }

        let columnList = schema.columns.map(\.columnName).joined(separator: ", ")
        var object: [String: Any]?

        try database.forEach(matchingQuery: "SELECT \(columnList) FROM \(tableName) WHERE llvs_id = ?",
            withBindings: [valueId.rawValue]) { row in
            var result: [String: Any] = [:]
            for (index, column) in self.schema.columns.enumerated() {
                if let propertyValue = Self.propertyValue(from: row, at: index, column: column) {
                    result[column.propertyName] = propertyValue
                }
            }
            object = result
        }

        guard let object else { return nil }
        // Sorted keys so an unchanged row produces identical bytes, and nothing comparing
        // data sees a change that is not one.
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Reads one column into the value the stored JSON should carry for its property.
    /// Shared with the typed read, which needs the same mapping in the same direction.
    static func propertyValue(from row: SQLiteDatabase.Row, at index: Int, column: ModelColumn) -> Any? {
        switch column.storage {
        case .date:
            // The column holds Unix seconds, because that is what SQL means by a timestamp.
            // Codable wants seconds since 2001, so convert here rather than storing a number
            // that ordinary SQL would read as 31 years out.
            guard let unixSeconds: Int64 = row.value(inColumnAtIndex: index) else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(unixSeconds)).timeIntervalSinceReferenceDate
        case .json:
            guard let text: String = row.value(inColumnAtIndex: index) else { return nil }
            return try? JSONSerialization.jsonObject(with: Data(text.utf8))
        case .scalar:
            switch column.declaration {
            case "TEXT":
                return row.value(inColumnAtIndex: index) as String?
            case "INTEGER":
                return row.value(inColumnAtIndex: index) as Int64?
            case "REAL":
                return row.value(inColumnAtIndex: index) as Double?
            case "BLOB":
                // Codable encodes Data as base64, so that is what it decodes from.
                return (row.value(inColumnAtIndex: index) as Data?)?.base64EncodedString()
            default:
                return nil
            }
        }
    }
}
