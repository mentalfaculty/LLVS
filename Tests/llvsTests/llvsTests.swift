import XCTest
@testable import llvs

final class llvsTests: XCTestCase {
    func testExample() {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
        XCTAssertEqual(llvs().text, "Hello, World!")
    }

    static var allTests = [
        ("testExample", testExample),
    ]
}
