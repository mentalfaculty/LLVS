//
//  Version.swift
//  llvs
//
//  Created by Drew McCormack on 31/10/2018.
//

import Foundation

public struct Version: Codable {
    public var identifier: String = UUID().uuidString
}

public struct Snapshot {
    public var version: Version
    public var parentage: (Version, Version?)?
}
