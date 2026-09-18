import Foundation
import Testing
@testable import LLVS

@Suite struct CacheTests {

    @Test func storedValueIsRetrievable() {
        let cache = Cache<Int>()
        cache.setValue(1, for: "a")
        #expect(cache.value(for: "a") == 1)
    }

    @Test func oldestGenerationIsEvicted() {
        let cache = Cache<Int>(numberOfGenerations: 2, regenerationLimit: 2)
        // Each generation takes 3 values before the next insert regenerates.
        // 7 inserts cause 2 regenerations, which pushes the first generation out.
        for i in 1...7 {
            cache.setValue(i, for: i)
        }
        #expect(cache.value(for: 1) == nil)
        #expect(cache.value(for: 4) == 4)
        #expect(cache.value(for: 7) == 7)
    }
}
