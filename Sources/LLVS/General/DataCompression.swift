//
//  DataCompression.swift
//  LLVS
//
//  Created by Drew McCormack on 01/03/2026.
//

import Foundation

/// Transparent compression/decompression using LZFSE via Foundation's NSData API.
/// Compressed data is prefixed with a 4-byte magic header ("LLZF") for reliable detection.
/// Uncompressed data (legacy or too small to benefit) is returned as-is on read.
public enum DataCompression {

    /// Magic bytes prepended to compressed data: "LLZF"
    private static let magic: [UInt8] = [0x4C, 0x4C, 0x5A, 0x46]

    /// Minimum data size worth attempting compression.
    private static let minimumCompressionSize = 64

    /// Compresses data using LZFSE. Returns original data if the input is too small
    /// or compression doesn't reduce size (accounting for the 4-byte magic header).
    public static func compress(_ data: Data) -> Data {
        guard data.count > minimumCompressionSize else { return data }
        guard let compressed = try? (data as NSData).compressed(using: .lzfse) as Data else { return data }
        guard compressed.count + magic.count < data.count else { return data }
        var result = Data(magic)
        result.append(compressed)
        return result
    }

    /// Decompresses data if it starts with the "LLZF" magic header.
    /// Data without the header (legacy uncompressed or small data) is returned as-is.
    public static func decompressIfNeeded(_ data: Data) -> Data {
        guard data.count > magic.count else { return data }
        let s = data.startIndex
        guard data[s] == magic[0], data[s+1] == magic[1],
              data[s+2] == magic[2], data[s+3] == magic[3] else {
            return data
        }
        let compressed = Data(data[(s + magic.count)...])
        guard let decompressed = try? (compressed as NSData).decompressed(using: .lzfse) as Data else {
            return data
        }
        return decompressed
    }
}

// MARK: - Value.Change Helpers

internal extension DataCompression {

    /// Compresses the data payload within Value.Change insert/update cases.
    static func compressValueChanges(_ changes: [Value.Change]) -> [Value.Change] {
        return changes.map { change in
            switch change {
            case .insert(let value):
                var v = value
                v.data = compress(v.data)
                return .insert(v)
            case .update(let value):
                var v = value
                v.data = compress(v.data)
                return .update(v)
            case .remove, .preserve, .preserveRemoval:
                return change
            }
        }
    }

    /// Decompresses the data payload within Value.Change insert/update cases.
    static func decompressValueChanges(_ changes: [Value.Change]) -> [Value.Change] {
        return changes.map { change in
            switch change {
            case .insert(let value):
                var v = value
                v.data = decompressIfNeeded(v.data)
                return .insert(v)
            case .update(let value):
                var v = value
                v.data = decompressIfNeeded(v.data)
                return .update(v)
            case .remove, .preserve, .preserveRemoval:
                return change
            }
        }
    }
}
