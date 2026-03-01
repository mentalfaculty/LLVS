//
//  DataCompressionTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 01/03/2026.
//

import XCTest
import Foundation
@testable import LLVS

class DataCompressionTests: XCTestCase {

    func testRoundTripJSON() {
        // Repetitive JSON compresses well and exceeds the minimum size threshold
        let json = """
        {"rawValue":"550e8400-e29b-41d4-a716-446655440000","storedVersionId":"6ba7b810-9dad-11d1-80b4-00c04fd430c8","valueReference":{"valueId":"test-value","storedVersionId":"550e8400-e29b-41d4-a716-446655440000"}}
        """
        let original = json.data(using: .utf8)!
        let compressed = DataCompression.compress(original)
        XCTAssertLessThan(compressed.count, original.count)
        let decompressed = DataCompression.decompressIfNeeded(compressed)
        XCTAssertEqual(decompressed, original)
    }

    func testRoundTripBinaryData() {
        // Large binary data with some repetition
        var data = Data(count: 1000)
        for i in 0..<data.count {
            data[i] = UInt8(i % 10)
        }
        let compressed = DataCompression.compress(data)
        XCTAssertLessThan(compressed.count, data.count)
        let decompressed = DataCompression.decompressIfNeeded(compressed)
        XCTAssertEqual(decompressed, data)
    }

    func testSmallDataNotCompressed() {
        let small = Data([0x01, 0x02, 0x03, 0x04])
        let result = DataCompression.compress(small)
        XCTAssertEqual(result, small, "Data below threshold should not be compressed")
    }

    func testEmptyData() {
        let empty = Data()
        XCTAssertEqual(DataCompression.compress(empty), empty)
        XCTAssertEqual(DataCompression.decompressIfNeeded(empty), empty)
    }

    func testLegacyUncompressedJSONPassesThrough() {
        let json = "{\"key\":\"value\"}".data(using: .utf8)!
        let result = DataCompression.decompressIfNeeded(json)
        XCTAssertEqual(result, json, "Uncompressed JSON should pass through unchanged")
    }

    func testLegacyUncompressedArrayPassesThrough() {
        let json = "[1,2,3]".data(using: .utf8)!
        let result = DataCompression.decompressIfNeeded(json)
        XCTAssertEqual(result, json, "Uncompressed JSON array should pass through unchanged")
    }

    func testLegacyBinaryDataPassesThrough() {
        // Binary data that doesn't start with LLZF magic
        let binary = Data([0xFF, 0xFE, 0xFD, 0xFC, 0xFB])
        let result = DataCompression.decompressIfNeeded(binary)
        XCTAssertEqual(result, binary, "Non-compressed binary data should pass through unchanged")
    }

    func testIncompressibleDataNotCompressed() {
        // Random data that doesn't compress well
        var random = Data(count: 200)
        for i in 0..<random.count {
            random[i] = UInt8.random(in: 0...255)
        }
        let result = DataCompression.compress(random)
        // Either returns original (compression didn't help) or compressed version
        let decompressed = DataCompression.decompressIfNeeded(result)
        XCTAssertEqual(decompressed, random, "Round-trip should preserve data even if compression didn't help")
    }

    func testCompressedDataHasMagicPrefix() {
        let json = String(repeating: "{\"key\":\"value\"},", count: 20).data(using: .utf8)!
        let compressed = DataCompression.compress(json)
        XCTAssertNotEqual(compressed, json, "Repetitive data should be compressed")
        // Check LLZF magic prefix
        XCTAssertEqual(compressed[0], 0x4C) // 'L'
        XCTAssertEqual(compressed[1], 0x4C) // 'L'
        XCTAssertEqual(compressed[2], 0x5A) // 'Z'
        XCTAssertEqual(compressed[3], 0x46) // 'F'
    }

    func testLargeDataRoundTrip() {
        // Simulate a realistic map node with repeated UUID patterns
        var parts: [String] = []
        for _ in 0..<50 {
            parts.append("\"\(UUID().uuidString)\":{\"storedVersionId\":\"\(UUID().uuidString)\"}")
        }
        let json = "{\(parts.joined(separator: ","))}".data(using: .utf8)!
        let compressed = DataCompression.compress(json)
        XCTAssertLessThan(compressed.count, json.count)
        let decompressed = DataCompression.decompressIfNeeded(compressed)
        XCTAssertEqual(decompressed, json)
    }
}
