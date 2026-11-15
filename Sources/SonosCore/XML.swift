import Foundation

public enum SonosError: LocalizedError {
    case invalidAddress, invalidXML, invalidResponse, notSonos, noSpeakers
    case network(String), device(String)
    public var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Enter a local IPv4 address, such as 192.168.1.25."
        case .invalidXML: return "The speaker returned an unreadable response."
        case .invalidResponse: return "The speaker returned an unexpected response. Try refreshing."
        case .notSonos: return "That address doesn't appear to be a Sonos speaker."
        case .noSpeakers: return "No Sonos speakers found. Check that your Mac and speakers are on the same network."
        case .network(let message): return message
        case .device(let message): return "Sonos couldn't complete the request: \(message)."
        }
    }
}

public final class XMLElement {
    public let name: String
    public let attributes: [String: String]
    public var text = ""
    public var children: [XMLElement] = []
    init(name: String, attributes: [String: String]) {
        self.name = name.split(separator: ":").last.map(String.init) ?? name
        self.attributes = attributes
    }
    public func first(_ name: String) -> XMLElement? {
        if self.name == name { return self }
        for child in children { if let result = child.first(name) { return result } }
        return nil
    }
    public func all(_ name: String) -> [XMLElement] {
        (self.name == name ? [self] : []) + children.flatMap { $0.all(name) }
    }
}

private final class XMLReader: NSObject, XMLParserDelegate {
    var stack: [XMLElement] = []
    var root: XMLElement?
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        guard stack.count < 64 else { parser.abortParsing(); return }
        let node = XMLElement(name: name, attributes: attributes)
        stack.last?.children.append(node)
        if root == nil { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { _ = stack.popLast() }
}

public enum SonosXML {
    public static func parse(_ data: Data) throws -> XMLElement {
        guard data.count < 2_000_000 else { throw SonosError.invalidXML }
        let reader = XMLReader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), let root = reader.root else { throw SonosError.invalidXML }
        return root
    }
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
