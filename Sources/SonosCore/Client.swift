import Foundation

public enum SonosService: String, Sendable {
    case rendering = "RenderingControl", group = "GroupRenderingControl", topology = "ZoneGroupTopology"
    public var urn: String { "urn:schemas-upnp-org:service:\(rawValue):1" }
    public var path: String { self == .topology ? "/ZoneGroupTopology/Control" : "/MediaRenderer/\(rawValue)/Control" }
}

public enum SOAP {
    public static func request(baseURL: URL, service: SonosService, action: String, arguments: [(String, String)]) throws -> URLRequest {
        let origin = try LocalAddress.origin(of: baseURL)
        var request = URLRequest(url: origin.appendingPathComponent(service.path), timeoutInterval: 4)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service.urn)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        let args = arguments.map { "<\($0.0)>\(SonosXML.escape($0.1))</\($0.0)>" }.joined()
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:\(action) xmlns:u="\(service.urn)">\(args)</u:\(action)></s:Body></s:Envelope>
        """.utf8)
        return request
    }
    public static func response(_ data: Data, statusCode: Int) throws -> XMLElement {
        let xml = try SonosXML.parse(data)
        if let fault = xml.first("Fault") {
            let description = fault.first("errorDescription")?.text ?? fault.first("faultstring")?.text ?? "Unknown error"
            let code = fault.first("errorCode")?.text ?? ""
            throw SonosError.device(code.isEmpty ? description : "\(description) (\(code))")
        }
        guard (200..<300).contains(statusCode), xml.first("Body") != nil else { throw SonosError.invalidResponse }
        return xml
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public final class SonosClient: @unchecked Sendable {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }
    private func send(_ base: URL, _ service: SonosService, _ action: String, _ args: [(String, String)] = []) async throws -> XMLElement {
        let request = try SOAP.request(baseURL: base, service: service, action: action, arguments: args)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw SonosError.invalidResponse }
        let xml = try SOAP.response(data, statusCode: response.statusCode)
        guard xml.first(action + "Response") != nil else { throw SonosError.invalidResponse }
        return xml
    }
    public func model(at base: URL) async throws -> String {
        let origin = try LocalAddress.origin(of: base)
        let (data, response) = try await session.data(from: origin.appendingPathComponent("xml/device_description.xml"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SonosError.invalidResponse }
        let xml = try SonosXML.parse(data)
        guard xml.first("manufacturer")?.text.lowercased().contains("sonos") == true else { throw SonosError.notSonos }
        return xml.first("modelName")?.text ?? "Sonos"
    }
    public func groups(at base: URL) async throws -> [SpeakerGroup] {
        let response = try await send(base, .topology, "GetZoneGroupState")
        guard let state = response.first("ZoneGroupState")?.text else { throw SonosError.invalidResponse }
        let groups = try Topology.parse(state)
        guard !groups.isEmpty else { throw SonosError.noSpeakers }
        return groups
    }
    public func read(at base: URL, group: Bool = false) async throws -> VolumeState {
        let service: SonosService = group ? .group : .rendering
        let args = group ? [("InstanceID", "0")] : [("InstanceID", "0"), ("Channel", "Master")]
        async let volumeXML = send(base, service, group ? "GetGroupVolume" : "GetVolume", args)
        async let muteXML = send(base, service, group ? "GetGroupMute" : "GetMute", args)
        let (v, m) = try await (volumeXML, muteXML)
        guard let raw = v.first("CurrentVolume")?.text, let volume = Int(raw), (0...100).contains(volume),
              let mute = m.first("CurrentMute")?.text, ["0", "1", "true", "false"].contains(mute) else { throw SonosError.invalidResponse }
        return VolumeState(volume: volume, muted: mute == "1" || mute == "true")
    }
    public func snapshotGroup(at base: URL) async throws {
        _ = try await send(base, .group, "SnapshotGroupVolume", [("InstanceID", "0")])
    }
    public func setVolume(at base: URL, group: Bool = false, volume: Int) async throws {
        var args = [("InstanceID", "0")]
        if !group { args.append(("Channel", "Master")) }
        args.append(("DesiredVolume", String(min(100, max(0, volume)))))
        _ = try await send(base, group ? .group : .rendering, group ? "SetGroupVolume" : "SetVolume", args)
    }
    public func setMute(at base: URL, group: Bool = false, muted: Bool) async throws {
        var args = [("InstanceID", "0")]
        if !group { args.append(("Channel", "Master")) }
        args.append(("DesiredMute", muted ? "1" : "0"))
        _ = try await send(base, group ? .group : .rendering, group ? "SetGroupMute" : "SetMute", args)
    }
}
