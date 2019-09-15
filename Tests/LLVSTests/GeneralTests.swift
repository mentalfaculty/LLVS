//
//  File.swift
//  
//
//  Created by Drew McCormack on 15/09/2019.
//

import Foundation
import XCTest
@testable import LLVS

class GeneralTests: XCTestCase {
    
    func testRangeSplitting() {
        XCTAssertEqual((5...10).split(intoRangesOfLength: 2), [5...6, 7...8, 9...10])
        XCTAssertEqual((5...10).split(intoRangesOfLength: 3), [5...7, 8...10])
        XCTAssertEqual((5...10).split(intoRangesOfLength: 4), [5...8, 9...10])
        XCTAssertEqual((5...10).split(intoRangesOfLength: 5), [5...9, 10...10])
        XCTAssertEqual((5...10).split(intoRangesOfLength: 6), [5...10])
        XCTAssertEqual((5...10).split(intoRangesOfLength: 7), [5...10])
        XCTAssertEqual((5...5).split(intoRangesOfLength: 2), [5...5])
    }
    
    static var allTests = [
        ("testRangeSplitting", testRangeSplitting),
    ]
}
