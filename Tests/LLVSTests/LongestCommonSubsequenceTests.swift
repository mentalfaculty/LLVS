//
//  LongestCommonSubsequenceTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 02/04/2019.
//

import XCTest
@testable import LLVS

class LongestCommonSubsequenceTests: XCTestCase {

    var lcs: LongestCommonSubsequence<Int>!
    
    func testSimpleSequence() {
        lcs = LongestCommonSubsequence(originalValues: [1,3], newValues: [1,2])
        XCTAssertEqual(lcs.length, 1)
        XCTAssertEqual(lcs.subsequenceOriginalIndexes, [0])
        XCTAssertEqual(lcs.subsequenceNewIndexes, [0])
    }
    
    func testRemovingFromSequence() {
        lcs = LongestCommonSubsequence(originalValues: [1,2,3,4,5,6,7], newValues: [1,2,4,5,7])
        XCTAssertEqual(lcs.length, 5)
        XCTAssertEqual(lcs.subsequenceOriginalIndexes, [0,1,3,4,6])
        XCTAssertEqual(lcs.subsequenceNewIndexes, [0,1,2,3,4])
    }
    
    func testAddingAndRemovingSequence() {
        lcs = LongestCommonSubsequence(originalValues: [1,2,3,4,5,6,7], newValues: [2,33,4,36,55,6,7])
        XCTAssertEqual(lcs.length, 4)
        XCTAssertEqual(lcs.subsequenceOriginalIndexes, [1,3,5,6])
        XCTAssertEqual(lcs.subsequenceNewIndexes, [0,2,5,6])
    }

    static var allTests = [
        ("testSimpleSequence", testSimpleSequence),
    ]
}
