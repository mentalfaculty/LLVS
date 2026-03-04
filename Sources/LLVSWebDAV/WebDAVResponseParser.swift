//
//  WebDAVResponseParser.swift
//  LLVSWebDAV
//
//  Created by Drew McCormack on 03/03/2026.
//

import Foundation
import LLVS

/// Parses PROPFIND XML responses from a WebDAV server.
/// Handles namespace variations (`D:`, `lp1:`, etc.) for broad server compatibility.
final class WebDAVResponseParser: NSObject, XMLParserDelegate, @unchecked Sendable {

    struct Item {
        let name: String
        let isDirectory: Bool
    }

    private let xmlParser: XMLParser
    private var items: [Item] = []
    private var characters = ""
    private var currentItemDictionary: [String: Any]?

    var parsedItems: [Item] { items }

    init(data: Data) {
        xmlParser = XMLParser(data: data)
        super.init()
        xmlParser.delegate = self
    }

    func parse() throws {
        let success = xmlParser.parse()
        if !success {
            throw xmlParser.parserError ?? CloudFileSystemError.serverError(statusCode: 0)
        }
    }

    // MARK: - Element Matching

    /// Matches element names with or without common WebDAV namespace prefixes.
    private func element(_ element: String, matches other: String) -> Bool {
        if element.caseInsensitiveCompare(other) == .orderedSame { return true }
        if ("D:" + element).caseInsensitiveCompare(other) == .orderedSame { return true }
        if ("lp1:" + element).caseInsensitiveCompare(other) == .orderedSame { return true }
        return false
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        characters = ""
        if element(elementName, matches: "D:response") {
            currentItemDictionary = [:]
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if element(elementName, matches: "D:href") {
            currentItemDictionary?["path"] = characters.removingPercentEncoding ?? characters
        } else if element(elementName, matches: "D:collection") {
            currentItemDictionary?["isDirectory"] = true
        } else if element(elementName, matches: "D:response"),
                  let dict = currentItemDictionary,
                  let path = dict["path"] as? String {
            let isDir = dict["isDirectory"] as? Bool ?? false
            let name = (path as NSString).lastPathComponent
            items.append(Item(name: name, isDirectory: isDir))
            currentItemDictionary = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        characters += string
    }
}
