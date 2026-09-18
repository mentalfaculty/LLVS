//
//  WebDAVResponseParser.swift
//  LLVSWebDAV
//
//  Created by Drew McCormack on 03/03/2026.
//

import Foundation
import LLVS

/// Parses PROPFIND XML responses from a WebDAV server.
/// Matches elements on their local name, because a server can bind the DAV: namespace to any prefix.
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

    /// Matches on the local name, so `D:response`, `d:response`, `ns0:response` and `response` are all the same.
    /// A server can bind the DAV: namespace to any prefix.
    private func element(_ element: String, matches other: String) -> Bool {
        func localName(_ name: String) -> Substring { name.split(separator: ":").last ?? Substring(name) }
        return localName(element).caseInsensitiveCompare(localName(other)) == .orderedSame
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
            // The first href is the path. Servers can echo an empty href later, inside a 404 propstat.
            if currentItemDictionary?["path"] == nil {
                currentItemDictionary?["path"] = characters.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else if element(elementName, matches: "D:collection") {
            currentItemDictionary?["isDirectory"] = true
        } else if element(elementName, matches: "D:response"),
                  let dict = currentItemDictionary,
                  let path = dict["path"] as? String {
            let isDir = dict["isDirectory"] as? Bool ?? false
            // Take the last component before decoding, so that an encoded slash stays part of the name
            let encodedName = (path as NSString).lastPathComponent
            let name = encodedName.removingPercentEncoding ?? encodedName
            items.append(Item(name: name, isDirectory: isDir))
            currentItemDictionary = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        characters += string
    }
}
