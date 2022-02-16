import XCTest

#if !os(macOS) && !os(iOS)
public func allTests() -> [XCTestCaseEntry] {
    return [
        testCase(AsynchronousTaskTests.allTests),
        testCase(GeneralTests.allTests),
        testCase(StoreSetupTests.allTests),
        testCase(ValueTests.allTests),
        testCase(VersionTests.allTests),
        testCase(MergeTests.allTests),
        testCase(MostRecentBranchMergeArbiterTests.allTests),
        testCase(MostRecentChangeMergeArbiterTests.allTests),
        testCase(ArrayDiffTests.allTests),
        testCase(ValueChangesInVersionTests.allTests),
        testCase(FileZoneTests.allTests),
        testCase(SQLiteZoneTests.allTests),
        testCase(MapTests.allTests),
        testCase(DiffTests.allTests),
        testCase(DynamicTaskBatcherTests),
        testCase(HistoryTests.allTests),
        testCase(PrevailingValueTests.allTests),
        testCase(SerialHistoryTests.allTests),
        testCase(FileSystemExchangeTests.allTests),
        testCase(SharedStoreTests.allTests),
        testCase(PerformanceTests.allTests),
    ]
}
#endif
