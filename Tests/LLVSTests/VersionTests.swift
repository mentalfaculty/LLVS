//
//  VersionTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 26/01/2019.
//

import Testing
import Foundation
@testable import LLVS

@Suite class VersionTests {

    let fm = FileManager.default

    let store: Store
    let rootURL: URL
    let versionsURL: URL
    let version: Version

    init() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        versionsURL = rootURL.appendingPathComponent("versions")
        store = try Store(rootDirectoryURL: rootURL)
        version = try store.makeVersion(basedOn: nil, storing: [])
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    @Test func creationOfVersionFile() {
        let v = version.id.rawValue + ".json"
        let prefix = String(v.prefix(2))
        let postfix = String(v.dropFirst(2))
        #expect(fm.fileExists(atPath: versionsURL.appendingPathComponent(prefix).appendingPathComponent(postfix).path))
    }

    @Test func loadingOfVersion() throws {
        let store = try Store(rootDirectoryURL: rootURL)
        store.queryHistory { history in
            #expect(history.headIdentifiers == [version.id])
        }
    }
}
