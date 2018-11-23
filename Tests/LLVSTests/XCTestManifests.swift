import XCTest

#if !os(macOS)
public func allTests() -> [XCTestCaseEntry] {
    return [
        testCase(StoreSetupTests.allTests),
        testCase(ValueTests.allTests),
        testCase(HistoryTests.allTests),
        testCase(PrevailingValueTests.allTests),
    ]
}
#endif
