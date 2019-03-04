import XCTest

#if !os(macOS)
public func allTests() -> [XCTestCaseEntry] {
    return [
        testCase(AsynchronousTaskTests.allTests),
        testCase(StoreSetupTests.allTests),
        testCase(ValueTests.allTests),
        testCase(ZoneTests.allTests),
        testCase(MapTests.allTests),
        testCase(DiffTests.allTests),
        testCase(HistoryTests.allTests),
        testCase(PrevailingValueTests.allTests),
        testCase(SerialHistoryTests.allTests),
        testCase(Performance.allTests),
    ]
}
#endif
