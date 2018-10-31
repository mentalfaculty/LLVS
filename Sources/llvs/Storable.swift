//
//  JSON.swift
//  llvs
//
//  Created by Drew McCormack on 31/10/2018.
//

import Foundation

public struct Identifier: Codable {
    public var identifierString: String = UUID().uuidString
}

public struct Value: Codable {
    var identifier: Identifier
    var version: Version?
    var properties: [String:String] = [:]
}
