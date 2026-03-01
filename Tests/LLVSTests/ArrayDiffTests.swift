//
//  ArrayDiffTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 02/04/2019.
//

import Testing
@testable import LLVS

@Suite struct ArrayDiffTests {

    var diff: LongestCommonSubsequence<Int>!

    @Test mutating func simpleSequence() {
        diff = LongestCommonSubsequence(originalValues: [1,3], finalValues: [1,2])
        #expect(diff.length == 1)
        #expect(diff.originalIndexesOfCommonElements == [0])
        #expect(diff.finalIndexesOfCommonElements == [0])
        #expect(diff.incrementalChanges == [.delete(originalIndex: 1, value: 3), .insert(finalIndex: 1, value: 2)])
    }

    @Test mutating func differingFirstElement() {
        diff = LongestCommonSubsequence(originalValues: [1,3], finalValues: [2,3])
        #expect(diff.length == 1)
        #expect(diff.originalIndexesOfCommonElements == [1])
        #expect(diff.finalIndexesOfCommonElements == [1])
        #expect(diff.incrementalChanges == [.delete(originalIndex: 0, value: 1), .insert(finalIndex: 0, value: 2)])
    }

    @Test mutating func removingFromSequence() {
        diff = LongestCommonSubsequence(originalValues: [1,2,3,4,5,6,7], finalValues: [1,2,4,5,7])
        #expect(diff.length == 5)
        #expect(diff.originalIndexesOfCommonElements == [0,1,3,4,6])
        #expect(diff.finalIndexesOfCommonElements == [0,1,2,3,4])
        #expect(diff.incrementalChanges == [.delete(originalIndex: 5, value: 6), .delete(originalIndex: 2, value: 3)])
    }

    @Test mutating func addingAndRemovingSequence() {
        diff = LongestCommonSubsequence(originalValues: [1,2,3,4,5,6,7], finalValues: [2,33,4,36,55,6,7])
        #expect(diff.length == 4)
        #expect(diff.originalIndexesOfCommonElements == [1,3,5,6])
        #expect(diff.finalIndexesOfCommonElements == [0,2,5,6])
        #expect(diff.incrementalChanges == [.delete(originalIndex: 4, value: 5), .delete(originalIndex: 2, value: 3), .delete(originalIndex: 0, value: 1), .insert(finalIndex: 1, value: 33), .insert(finalIndex: 3, value: 36), .insert(finalIndex: 4, value: 55)])
    }

    @Test func arrayFuncs() {
        let original = [1,2,3,4,5,6,7]
        let new = [2,33,4,36,55,6,7]
        let diff = original.diff(leadingTo: new)
        #expect(new == original.applying(diff))
    }

    @Test func empty() {
        let original: [Int] = []
        let new: [Int] = []
        let diff = original.diff(leadingTo: new)
        #expect([] == original.applying(diff))
    }

    @Test func originalEmpty() {
        let original: [Int] = []
        let new: [Int] = [1,2,3]
        let diff = original.diff(leadingTo: new)
        #expect(new == original.applying(diff))
    }

    @Test func finalEmpty() {
        let original: [Int] = [1,2,3]
        let new: [Int] = []
        let diff = original.diff(leadingTo: new)
        #expect(new == original.applying(diff))
    }

    @Test func merge() {
        let original: [Int] = [1,2]
        let new1: [Int] = [1,4]
        let new2: [Int] = [1,2,3]
        let diff1 = original.diff(leadingTo: new1)
        let diff2 = original.diff(leadingTo: new2)
        let mergeDiff = ArrayDiff(merging: diff1, with: diff2)
        #expect([1,4,3] == original.applying(mergeDiff))
    }

    @Test func mergeLongSequence() {
        let original: [Int] = [1,2,3,4,5,6,7,8,9,10]
        let new1: [Int] = [1,2,3,4,5,5,7,8,9,10]
        let new2: [Int] = [1,2,3,4,5,6,7,8,10,10]
        let diff1 = original.diff(leadingTo: new1)
        let diff2 = original.diff(leadingTo: new2)
        let mergeDiff = ArrayDiff(merging: diff1, with: diff2)
        #expect([1,2,3,4,5,5,7,8,10,10] == original.applying(mergeDiff))
    }

    @Test func twoDeleteMerge() {
        let original: [Int] = [1,2,3]
        let new1: [Int] = [2,3]
        let new2: [Int] = [2,3,4]
        let diff1 = original.diff(leadingTo: new1)
        let diff2 = original.diff(leadingTo: new2)
        let mergeDiff = ArrayDiff(merging: diff1, with: diff2)
        #expect([2,3,4] == original.applying(mergeDiff))
    }

    @Test func fourDeleteMerge() {
        let original: [Int] = [1,2,3]
        let new1: [Int] = [3]
        let new2: [Int] = [1]
        let diff1 = original.diff(leadingTo: new1)
        let diff2 = original.diff(leadingTo: new2)
        let mergeDiff = ArrayDiff(merging: diff1, with: diff2)
        #expect([] as [Int] == original.applying(mergeDiff))
    }

    @Test func mergeBranchEmpty() {
        let original: [Int] = [1,2,3]
        let new1: [Int] = []
        let new2: [Int] = [2,3,4]
        let diff1 = original.diff(leadingTo: new1)
        let diff2 = original.diff(leadingTo: new2)
        let mergeDiff = ArrayDiff(merging: diff1, with: diff2)
        #expect([4] == original.applying(mergeDiff))
    }

    @Test func mergeOriginalEmpty() {
        let original: [Int] = []
        let new1: [Int] = [1,2,3]
        let new2: [Int] = [2,3,4]
        let diff1 = original.diff(leadingTo: new1)
        let diff2 = original.diff(leadingTo: new2)
        let mergeDiff = ArrayDiff(merging: diff1, with: diff2)
        #expect([1,2,3,2,3,4] == original.applying(mergeDiff))
    }

    @Test func mergeAllEmpty() {
        let original: [Int] = []
        let new1: [Int] = []
        let new2: [Int] = []
        let diff1 = original.diff(leadingTo: new1)
        let diff2 = original.diff(leadingTo: new2)
        let mergeDiff = ArrayDiff(merging: diff1, with: diff2)
        #expect([] as [Int] == original.applying(mergeDiff))
    }

    @Test func complexMerge() {
        let original: [Int] = [1,2,3,4,5]
        let new1: [Int] = [2,3,6,7]
        let new2: [Int] = [0,2,3,4,8,9]
        let diff1 = original.diff(leadingTo: new1)
        let diff2 = original.diff(leadingTo: new2)
        let mergeDiff = ArrayDiff(merging: diff1, with: diff2)
        #expect([0,2,3,6,7,8,9] == original.applying(mergeDiff))
    }

    @Test func deletesOverlappingInsertsMerge() {
        let original: [Int] = [1,2,3,4,5]
        let new1: [Int] = [1,4,5]
        let new2: [Int] = [1,6,7,2,3,4,5]
        let diff1 = original.diff(leadingTo: new1)
        let diff2 = original.diff(leadingTo: new2)
        let mergeDiff = ArrayDiff(merging: diff1, with: diff2)
        #expect([1,6,7,4,5] == original.applying(mergeDiff))
    }

    @Test func insertAtEndMerge() {
        let original: [Int] = [1,2,3]
        let new1: [Int] = [1,2,3,4]
        let new2: [Int] = [1,2,3]
        let diff1 = original.diff(leadingTo: new1)
        let diff2 = original.diff(leadingTo: new2)
        let mergeDiff = ArrayDiff(merging: diff1, with: diff2)
        #expect([1,2,3,4] == original.applying(mergeDiff))
    }

    @Test func deleteAndInsertAtEndMerge() {
        let original: [Int] = [1,2,3]
        let new1: [Int] = [1,2,3,4]
        let new2: [Int] = [1,2]
        let diff1 = original.diff(leadingTo: new1)
        let diff2 = original.diff(leadingTo: new2)
        let mergeDiff = ArrayDiff(merging: diff1, with: diff2)
        #expect([1,2,4] == original.applying(mergeDiff))
    }
}
