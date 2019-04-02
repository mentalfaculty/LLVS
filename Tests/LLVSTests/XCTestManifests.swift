import XCTest

#if !os(macOS)
public func allTests() -> [XCTestCaseEntry] {
    return [
        testCase(AsynchronousTaskTests.allTests),
        testCase(StoreSetupTests.allTests),
        testCase(ValueTests.allTests),
        testCase(VersionTests.allTests),
        testCase(MergeTests.allTests),
        testCase(MostRecentBranchArbiterTests.allTests),
        testCase(MostRecentChangeArbiterTests.allTests),
        testCase(LongestCommonSubsequenceTests.allTests),
        testCase(ValueChangesInVersionsTests.allTests),
        testCase(ZoneTests.allTests),
        testCase(MapTests.allTests),
        testCase(DiffTests.allTests),
        testCase(HistoryTests.allTests),
        testCase(PrevailingValueTests.allTests),
        testCase(SerialHistoryTests.allTests),
        testCase(FileSystemExchangeTests.allTests),
        testCase(SharedStoreTests.allTests),
        testCase(Performance.allTests),
    ]
}
#endif
