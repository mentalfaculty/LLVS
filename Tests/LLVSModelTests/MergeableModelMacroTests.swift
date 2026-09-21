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

@MergeableModel
struct SchemaModel: Codable, Equatable {
    var title: String = ""
    var count: Int = 0
    var ratio: Double = 0
    var starred: Bool = false
    var when: Date = .init(timeIntervalSince1970: 0)
    var identifier: UUID = .init()
    var payload: Data = .init()
    var note: String? = nil
    var tags: [String] = []
    var updatedAt: Date = .init(timeIntervalSince1970: 0)
}

@MergeableModel
struct InferredTypeModel: Codable, Equatable {
    var typed: String = ""
    var inferred = 0
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

    // MARK: - Generated SQLite schema

    private func columns(of schema: ModelSchema) -> [String: ModelColumn] {
        Dictionary(uniqueKeysWithValues: schema.columns.map { ($0.propertyName, $0) })
    }

    @Test func scalarPropertiesBecomeRealColumns() {
        let byProperty = columns(of: SchemaModel.sqliteSchema)
        #expect(byProperty["title"]?.declaration == "TEXT")
        #expect(byProperty["count"]?.declaration == "INTEGER")
        #expect(byProperty["ratio"]?.declaration == "REAL")
        #expect(byProperty["starred"]?.declaration == "INTEGER")
        // A Date is INTEGER, but its own storage case: the column holds Unix seconds while
        // Codable encodes seconds since 2001, so the two need telling apart.
        #expect(byProperty["when"]?.declaration == "INTEGER")
        #expect(byProperty["when"]?.storage == .date)
        #expect(byProperty["identifier"]?.declaration == "TEXT")
        #expect(byProperty["payload"]?.declaration == "BLOB")
        #expect(byProperty["title"]?.storage == .scalar)
    }

    @Test func optionalScalarsAreStillScalarColumns() {
        let byProperty = columns(of: SchemaModel.sqliteSchema)
        #expect(byProperty["note"]?.declaration == "TEXT")
        #expect(byProperty["note"]?.storage == .scalar)
    }

    @Test func nestedPropertiesBecomeJSONColumns() {
        let byProperty = columns(of: SchemaModel.sqliteSchema)
        #expect(byProperty["tags"]?.declaration == "TEXT")
        #expect(byProperty["tags"]?.storage == .json)
    }

    @Test func columnNamesAreSnakeCased() {
        let byProperty = columns(of: SchemaModel.sqliteSchema)
        #expect(byProperty["updatedAt"]?.columnName == "updated_at")
    }

    /// `when` is a SQLite keyword, so a bare column of that name would be a syntax error.
    @Test func aKeywordColumnNameIsEscaped() {
        let byProperty = columns(of: SchemaModel.sqliteSchema)
        #expect(byProperty["when"]?.columnName == "when_")
    }

    @Test func aPropertyWithNoTypeAnnotationGetsNoColumn() {
        // A macro sees only syntax, so an inferred type is invisible. Omitted, not guessed.
        let names = InferredTypeModel.sqliteSchema.columns.map(\.propertyName)
        #expect(names == ["typed"])
        #expect(InferredTypeModel.sqliteSchema.propertiesWithoutColumns == ["inferred"])
    }
}
