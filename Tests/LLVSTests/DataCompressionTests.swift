//
//  DataCompressionTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 01/03/2026.
//

import Testing
import Foundation
@testable import LLVS

@Suite struct DataCompressionTests {

    @Test func roundTripJSON() {
        // Repetitive JSON compresses well and exceeds the minimum size threshold
        let json = """
        {"rawValue":"550e8400-e29b-41d4-a716-446655440000","storedVersionId":"6ba7b810-9dad-11d1-80b4-00c04fd430c8","valueReference":{"valueId":"test-value","storedVersionId":"550e8400-e29b-41d4-a716-446655440000"}}
        """
        let original = json.data(using: .utf8)!
        let compressed = DataCompression.compress(original)
        #expect(compressed.count < original.count)
        let decompressed = DataCompression.decompressIfNeeded(compressed)
        #expect(decompressed == original)
    }

    @Test func roundTripBinaryData() {
        // Large binary data with some repetition
        var data = Data(count: 1000)
        for i in 0..<data.count {
            data[i] = UInt8(i % 10)
        }
        let compressed = DataCompression.compress(data)
        #expect(compressed.count < data.count)
        let decompressed = DataCompression.decompressIfNeeded(compressed)
        #expect(decompressed == data)
    }

    @Test func smallDataNotCompressed() {
        let small = Data([0x01, 0x02, 0x03, 0x04])
        let result = DataCompression.compress(small)
        #expect(result == small, "Data below threshold should not be compressed")
    }

    @Test func emptyData() {
        let empty = Data()
        #expect(DataCompression.compress(empty) == empty)
        #expect(DataCompression.decompressIfNeeded(empty) == empty)
    }

    @Test func legacyUncompressedJSONPassesThrough() {
        let json = "{\"key\":\"value\"}".data(using: .utf8)!
        let result = DataCompression.decompressIfNeeded(json)
        #expect(result == json, "Uncompressed JSON should pass through unchanged")
    }

    @Test func legacyUncompressedArrayPassesThrough() {
        let json = "[1,2,3]".data(using: .utf8)!
        let result = DataCompression.decompressIfNeeded(json)
        #expect(result == json, "Uncompressed JSON array should pass through unchanged")
    }

    @Test func legacyBinaryDataPassesThrough() {
        // Binary data that doesn't start with LLZF magic
        let binary = Data([0xFF, 0xFE, 0xFD, 0xFC, 0xFB])
        let result = DataCompression.decompressIfNeeded(binary)
        #expect(result == binary, "Non-compressed binary data should pass through unchanged")
    }

    @Test func incompressibleDataNotCompressed() {
        // Random data that doesn't compress well
        var random = Data(count: 200)
        for i in 0..<random.count {
            random[i] = UInt8.random(in: 0...255)
        }
        let result = DataCompression.compress(random)
        // Either returns original (compression didn't help) or compressed version
        let decompressed = DataCompression.decompressIfNeeded(result)
        #expect(decompressed == random, "Round-trip should preserve data even if compression didn't help")
    }

    @Test func compressedDataHasMagicPrefix() {
        let json = String(repeating: "{\"key\":\"value\"},", count: 20).data(using: .utf8)!
        let compressed = DataCompression.compress(json)
        #expect(compressed != json, "Repetitive data should be compressed")
        // Check LLZF magic prefix
        #expect(compressed[0] == 0x4C) // 'L'
        #expect(compressed[1] == 0x4C) // 'L'
        #expect(compressed[2] == 0x5A) // 'Z'
        #expect(compressed[3] == 0x46) // 'F'
    }

    @Test func largeDataRoundTrip() {
        // Simulate a realistic map node with repeated UUID patterns
        var parts: [String] = []
        for _ in 0..<50 {
            parts.append("\"\(UUID().uuidString)\":{\"storedVersionId\":\"\(UUID().uuidString)\"}")
        }
        let json = "{\(parts.joined(separator: ","))}".data(using: .utf8)!
        let compressed = DataCompression.compress(json)
        #expect(compressed.count < json.count)
        let decompressed = DataCompression.decompressIfNeeded(compressed)
        #expect(decompressed == json)
    }
}
