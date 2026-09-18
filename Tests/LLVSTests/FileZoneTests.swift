//
//  FileZoneTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 07/12/2018.
//

import Testing
import Foundation
@testable import LLVS

@Suite class FileZoneTests {

    let fm = FileManager.default

    let zone: FileZone
    let rootURL: URL
    let ref: ZoneReference

    init() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        zone = FileZone(rootDirectory: rootURL, fileExtension: "json")
        ref = ZoneReference(key: "ABCDEF", version: .init("1234"))
    }

    deinit {
        try? fm.removeItem(at: rootURL)
    }

    @Test func creation() {
        #expect(fm.fileExists(atPath: rootURL.path))
    }

    @Test func addingDataCreatesFiles() throws {
        try zone.store(Data(), for: ref)
        fm.fileExists(atPath: rootURL.appendingPathComponent("AB/CDEF/1/234.json").path)
    }

    @Test func overwritingReplacesFileRatherThanWritingInPlace() throws {
        // An atomic write goes to a temporary file, which is then renamed over the original.
        // A hard link to the original keeps the old content. With an in-place write, a concurrent
        // reader (or a crash) can see a partly written file, and the hard link sees the new content.
        try zone.store("old".data(using: .utf8)!, for: ref)
        let (_, fileURL) = try zone.fileSystemLocation(for: ref)
        let linkURL = rootURL.appendingPathComponent("link")
        try fm.linkItem(at: fileURL, to: linkURL)

        try zone.store("new".data(using: .utf8)!, for: ref)

        let linked = DataCompression.decompressIfNeeded(try Data(contentsOf: linkURL))
        #expect(String(data: linked, encoding: .utf8) == "old")
    }

    @Test(.enabled(if: getuid() != 0, "root ignores file permissions")) func unreadableFileThrowsRatherThanReadingAsMissing() throws {
        // A value that exists but cannot be read is an error. Reporting it as missing
        // would make the store treat the value as removed.
        let data = Data((0..<20000).map { UInt8(truncatingIfNeeded: $0) }) // Too big for the zone cache
        try zone.store(data, for: ref)
        let (_, fileURL) = try zone.fileSystemLocation(for: ref)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path) }

        #expect(throws: (any Error).self) { try zone.data(for: ref) }
    }

    @Test func missingFileReadsAsNil() throws {
        #expect(try zone.data(for: ref) == nil)
    }

    @Test func addingMultipleReferencesInSameDiretories() throws {
        try zone.store(Data(), for: ref)
        try zone.store(Data(), for: .init(key: "ABCDEF", version: .init("1245")))
        fm.fileExists(atPath: rootURL.appendingPathComponent("AB/CDEF/1/245.json").path)
    }

    @Test func addingMultipleReferencesWithDifferentVersionDirectories() throws {
        try zone.store(Data(), for: ref)
        try zone.store(Data(), for: .init(key: "ABCDEF", version: .init("2222")))
        fm.fileExists(atPath: rootURL.appendingPathComponent("AB/CDEF/2/222.json").path)
    }

    @Test func retrievingNonExistentData() throws {
        let data = try zone.data(for: ref)
        #expect(data == nil)
    }

    @Test func retrievingData() throws {
        try zone.store("Test".data(using: .utf8)!, for: ref)
        let data = try zone.data(for: ref)
        #expect(data != nil)
        let string = String(bytes: data!, encoding: .utf8)
        #expect(string == "Test")
    }

    @Test func versionsQuery() throws {
        try zone.store(Data(), for: ref)
        try zone.store(Data(), for: .init(key: "ABCDEF", version: .init("1245")))
        let versions = try zone.versionIds(for: "ABCDEF")
        let versionStrings = versions.map { $0.rawValue }
        #expect(versions.count == 2)
        #expect(versionStrings.contains("1234"))
        #expect(versionStrings.contains("1245"))
    }
}
