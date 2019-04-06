//
//  ArrayDiffTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 02/04/2019.
//

import XCTest
@testable import LLVS

class ArrayDiffTests: XCTestCase {

    var diff: ArrayDiff<Int>!
    
    func testSimpleSequence() {
        diff = ArrayDiff(originalValues: [1,3], finalValues: [1,2])
        XCTAssertEqual(diff.length, 1)
        XCTAssertEqual(diff.originalIndexesOfCommonElements, [0])
        XCTAssertEqual(diff.finalIndexesOfCommonElements, [0])
        XCTAssertEqual(diff.incrementalChanges, [.delete(originalIndex: 1, value: 3), .insert(finalIndex: 1, value: 2)])
    }
    
    func testDifferingFirstElement() {
        diff = ArrayDiff(originalValues: [1,3], finalValues: [2,3])
        XCTAssertEqual(diff.length, 1)
        XCTAssertEqual(diff.originalIndexesOfCommonElements, [1])
        XCTAssertEqual(diff.finalIndexesOfCommonElements, [1])
        XCTAssertEqual(diff.incrementalChanges, [.delete(originalIndex: 0, value: 1), .insert(finalIndex: 0, value: 2)])
    }
    
    func testRemovingFromSequence() {
        diff = ArrayDiff(originalValues: [1,2,3,4,5,6,7], finalValues: [1,2,4,5,7])
        XCTAssertEqual(diff.length, 5)
        XCTAssertEqual(diff.originalIndexesOfCommonElements, [0,1,3,4,6])
        XCTAssertEqual(diff.finalIndexesOfCommonElements, [0,1,2,3,4])
        XCTAssertEqual(diff.incrementalChanges, [.delete(originalIndex: 5, value: 6), .delete(originalIndex: 2, value: 3)])
    }
    
    func testAddingAndRemovingSequence() {
        diff = ArrayDiff(originalValues: [1,2,3,4,5,6,7], finalValues: [2,33,4,36,55,6,7])
        XCTAssertEqual(diff.length, 4)
        XCTAssertEqual(diff.originalIndexesOfCommonElements, [1,3,5,6])
        XCTAssertEqual(diff.finalIndexesOfCommonElements, [0,2,5,6])
        XCTAssertEqual(diff.incrementalChanges, [.delete(originalIndex: 4, value: 5), .delete(originalIndex: 2, value: 3), .delete(originalIndex: 0, value: 1), .insert(finalIndex: 1, value: 33), .insert(finalIndex: 3, value: 36), .insert(finalIndex: 4, value: 55)])
    }
    
    func testArrayFuncs() {
        let original = [1,2,3,4,5,6,7]
        let new = [2,33,4,36,55,6,7]
        let diff = original.diff(leadingTo: new)
        XCTAssertEqual(new, original.applying(diff))
    }
    
    func testEmpty() {
        let original: [Int] = []
        let new: [Int] = []
        let diff = original.diff(leadingTo: new)
        XCTAssertEqual([], original.applying(diff))
    }
    
    func testOriginalEmpty() {
        let original: [Int] = []
        let new: [Int] = [1,2,3]
        let diff = original.diff(leadingTo: new)
        XCTAssertEqual(new, original.applying(diff))
    }
    
    func testFinalEmpty() {
        let original: [Int] = [1,2,3]
        let new: [Int] = []
        let diff = original.diff(leadingTo: new)
        XCTAssertEqual(new, original.applying(diff))
    }

    static var allTests = [
        ("testSimpleSequence", testSimpleSequence),
        ("testDifferingFirstElement", testDifferingFirstElement),
        ("testRemovingFromSequence", testRemovingFromSequence),
        ("testAddingAndRemovingSequence", testAddingAndRemovingSequence),
    ]
}
