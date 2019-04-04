//
//  ArrayMerge.swift
//  LLVS
//
//  Created by Drew McCormack on 02/04/2019.
//

import Foundation

/// See https://en.wikipedia.org/wiki/Longest_common_subsequence_problem
final class LongestCommonSubsequence<T: Equatable> {
    
    let originalValues: [T]
    let newValues: [T]
    private let table: Table
    public private(set) var subsequenceOriginalIndexes: [Int] = []
    public private(set) var subsequenceNewIndexes: [Int] = []
    public private(set) var deltas: [Delta] = []
    public var length: Int {
        guard !originalValues.isEmpty, !newValues.isEmpty else { return 0 }
        return table[(originalValues.count-1, newValues.count-1)].length
    }
    
    init(originalValues: [T], newValues: [T]) {
        self.originalValues = originalValues
        self.newValues = newValues
        self.table = Table(originalLength: self.originalValues.count, newLength: self.newValues.count)
        fillTable()
        findLongestSubsequence()
    }
    
    private func coordinate(to neighbor: Table.Neighbor, of coordinate: Table.Coordinate) -> Table.Coordinate {
        return neighbor.coordinate(from: coordinate)
    }
    
    private func fillTable() {
        for row in 0..<originalValues.count {
            for col in 0..<newValues.count {
                let coord = (row, col)
                let left = table[coordinate(to: .left, of: coord)]
                let top = table[coordinate(to: .top, of: coord)]
                var subsequence = table[coord]
                if originalValues[row] == newValues[col] {
                    let topLeft = table[coordinate(to: .topLeft, of: coord)]
                    subsequence.contributors = [.topLeft]
                    subsequence.length = topLeft.length+1
                } else if left.length > top.length {
                    subsequence.contributors = [.left]
                    subsequence.length = left.length
                } else if top.length > left.length {
                    subsequence.contributors = [.top]
                    subsequence.length = top.length
                } else {
                    subsequence.contributors = [.top, .left]
                    subsequence.length = top.length
                }
                table[coord] = subsequence
            }
        }
    }
    
    private func findLongestSubsequence() {
        guard !originalValues.isEmpty, !newValues.isEmpty else { return }
        
        // Begin at end and walk back to origin
        var coord = (originalValues.count-1, newValues.count-1)
        while coord.0 > -1 || coord.1 > -1 {
            let sub = table[coord]
            
            // Determine the preferred neighbor.
            // Update coord to that neighbor when finished this iteration.
            var preferred: Table.Neighbor?
            defer { coord = preferred!.coordinate(from: coord) }
            
            // Try to move diagonally
            preferred = sub.contributors.first { neighbor in
                let neighborSub = table[neighbor.coordinate(from: coord)]
                return neighborSub.length < sub.length
            }
            guard preferred == nil else {
                subsequenceOriginalIndexes.insert(coord.0, at: 0)
                subsequenceNewIndexes.insert(coord.1, at: 0)
                continue
            }
            
            // Otherwise pick first option
            preferred = sub.contributors.first
            switch preferred! {
            case .left:
                if coord.1 == -1 { break }
                let delta: Delta = .insert(coord.0+1, newValues[coord.1])
                deltas.insert(delta, at: 0)
            case .top:
                if coord.0 == -1 { break }
                let delta: Delta = .delete(coord.0)
                deltas.insert(delta, at: 0)
            case .topLeft:
                fatalError()
            }
        }
    }
    
    /// Delta indicates a change to the original array.
    /// Indexes are relative to the original indexes of the original array.
    enum Delta: Equatable {
        case insert(Int, T)
        case delete(Int)
    }
    
    final class Table: CustomDebugStringConvertible {
        
        typealias Coordinate = (original: Int, new: Int)
        
        enum Neighbor: String, CustomDebugStringConvertible {
            case left
            case top
            case topLeft
            
            var offset: Coordinate {
                switch self {
                case .left:
                    return (0,-1)
                case .top:
                    return (-1,0)
                case .topLeft:
                    return (-1,-1)
                }
            }
            
            func coordinate(from index: Coordinate) -> Coordinate {
                let offset = self.offset
                return (original: index.original + offset.original, new: index.new + offset.new)
            }
            
            var debugDescription: String {
                return self.rawValue
            }
        }
        
        struct Subsequence {
            typealias Length = Int
            var length: Length = 0
            var contributors: [Neighbor] = []
        }
        
        let originalLength: Int
        let newLength: Int
        private var subsequences: [Subsequence]
        
        init(originalLength: Int, newLength: Int) {
            self.originalLength = originalLength
            self.newLength = newLength
            self.subsequences = .init(repeating: Subsequence(), count: (originalLength+1) * (newLength+1))
            for row in 0..<originalLength {
                self[(row,-1)] = Subsequence(length: 0, contributors: [.top])
            }
            for col in 0..<newLength {
                self[(-1,col)] = Subsequence(length: 0, contributors: [.left])
            }
        }
        
        /// Coordinates correspond to the indexes in the original and new arrays.
        /// The storage elements themselves begin at -1, but that is an internal detail.
        subscript(coordinates: (original: Int, new: Int)) -> Subsequence {
            get {
                let i = (coordinates.original+1) * (newLength+1) + (coordinates.new+1)
                return subsequences[i]
            }
            set(newValue) {
                let i = (coordinates.original+1) * (newLength+1) + (coordinates.new+1)
                subsequences[i] = newValue
            }
        }
        
        var debugDescription: String {
            var result = ""
            for row in -1..<originalLength {
                var str = "\n"
                for col in -1..<newLength {
                    let sub = self[(row,col)]
                    str += "(\(sub.length), \(sub.contributors))".padding(toLength: 18, withPad: " ", startingAt: 0)
                }
                result += str
            }
            return result
        }
    }
}
