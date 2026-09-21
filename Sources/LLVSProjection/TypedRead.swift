//
//  TypedRead.swift
//  LLVS
//
//  Created by Drew McCormack on 21/09/2026.
//

import Foundation
import LLVS
import LLVSModel
import LLVSSQLite

/// A row read from an owned table, as the model plus where it came from.
///
/// The identity and version travel with the model rather than being dropped, so a row knows
/// which value it is and what it was read at. That is what a typed write would need for
/// optimistic concurrency, and it costs one level of nesting now rather than an API break later.
public struct ModelRow<Model: StorableModel & Sendable>: Sendable {
    public let model: Model
    public let id: Value.ID
    /// The version the table held when this was read, when the caller knows it.
    public let version: Version.ID?
}

extension OwnedTable {

    /// Reads rows and decodes them into the model.
    ///
    /// `clause` is appended after `WHERE`, with `bindings` bound to its placeholders. It is
    /// the caller's own SQL, so bind values rather than interpolating them.
    ///
    /// A row that cannot be decoded is left out rather than throwing, so one bad row does not
    /// blank a list. This mirrors how the read-only projection treats a value it cannot read.
    /// Skipped rows are logged, because otherwise a schema mismatch is indistinguishable from
    /// an empty table — which is exactly how a `Bool` column that could not decode hid itself.
    ///
    /// Writes stay ordinary SQL on purpose. An `UPDATE` naming one column says only that
    /// column changed, and the capture triggers record exactly that; a whole-row typed write
    /// would claim every column changed and cost the per-column merge.
    public func fetch<Model: StorableModel & Sendable>(
        _ type: Model.Type,
        in database: SQLiteDatabase,
        where clause: String? = nil,
        bindings: [Any?] = [],
        atVersion version: Version.ID? = nil
    ) throws -> [ModelRow<Model>] {
        let columnList = (["llvs_id"] + schema.columns.map(\.columnName)).joined(separator: ", ")
        var query = "SELECT \(columnList) FROM \(tableName)"
        if let clause { query += " WHERE \(clause)" }

        var rows: [ModelRow<Model>] = []
        var skipped: [Value.ID] = []
        let decoder = JSONDecoder()

        try database.forEach(matchingQuery: query, withBindings: bindings) { row in
            guard let rawId: String = row.value(inColumnAtIndex: 0) else { return }

            var object: [String: Any] = [:]
            for (offset, column) in self.schema.columns.enumerated() {
                // llvs_id occupies column 0, so the schema's columns start at 1.
                if let propertyValue = Self.propertyValue(from: row, at: offset + 1, column: column) {
                    object[column.propertyName] = propertyValue
                }
            }

            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let model = try? decoder.decode(Model.self, from: data) else {
                // A row the model cannot decode is left out, so one bad row does not blank a
                // list. Silence would make a schema mismatch look like an empty table, so say
                // so once per query rather than per row.
                skipped.append(Value.ID(rawId))
                return
            }
            rows.append(ModelRow(model: model, id: .init(rawId), version: version))
        }

        if !skipped.isEmpty {
            log.error("\(tableName): \(skipped.count) row(s) could not be decoded as \(Model.self) and were left out, starting with \(skipped[0].rawValue). The table's columns and the model may disagree; a rebuild would resolve it.")
        }

        return rows
    }
}
