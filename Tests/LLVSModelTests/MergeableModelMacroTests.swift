import Testing
import Foundation
@testable import LLVSModel

@MergeableModel
public struct PublicModel: Codable, Equatable {
    public var title: String = ""
    public var count: Int = 0
}

@MergeableModel
struct MultipleBindingModel: Codable, Equatable {
    var first = 0, second = 0
}

@Suite struct MergeableModelMacroTests {

    @Test func publicStructGetsPublicConformance() throws {
        let ancestor = PublicModel(title: "a", count: 1)
        var dominant = ancestor; dominant.title = "b"
        var subordinate = ancestor; subordinate.count = 2

        let merged = try dominant.merged(withSubordinate: subordinate, commonAncestor: ancestor)

        #expect(merged == PublicModel(title: "b", count: 2))
    }

    @Test func everyBindingInADeclarationIsMerged() throws {
        let ancestor = MultipleBindingModel(first: 1, second: 1)
        var dominant = ancestor; dominant.first = 2
        var subordinate = ancestor; subordinate.second = 3

        let merged = try dominant.merged(withSubordinate: subordinate, commonAncestor: ancestor)

        #expect(merged == MultipleBindingModel(first: 2, second: 3))
    }
}
