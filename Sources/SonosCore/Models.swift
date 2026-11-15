import Foundation

public struct Room: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let baseURL: URL
    public let isStereoPair: Bool
    public var model: String
    public init(id: String, name: String, baseURL: URL, isStereoPair: Bool = false, model: String = "Sonos") {
        self.id = id; self.name = name; self.baseURL = baseURL
        self.isStereoPair = isStereoPair; self.model = model
    }
}

public struct SpeakerGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let coordinatorURL: URL
    public var rooms: [Room]
    public init(id: String, coordinatorURL: URL, rooms: [Room]) {
        self.id = id; self.coordinatorURL = coordinatorURL; self.rooms = rooms
    }
}

public struct VolumeState: Equatable, Sendable {
    public let volume: Int
    public let muted: Bool
    public init(volume: Int, muted: Bool) { self.volume = min(100, max(0, volume)); self.muted = muted }
}

public enum LocalAddress {
    public static func isPrivateIPv4(_ host: String) -> Bool {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4, components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              components.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) else { return false }
        let octets = components.map { Int($0)! }
        return octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 169 && octets[1] == 254)
    }
    public static func baseURL(_ input: String) throws -> URL {
        let host = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPrivateIPv4(host), let url = URL(string: "http://\(host):1400") else { throw SonosError.invalidAddress }
        return url
    }
    public static func origin(of url: URL) throws -> URL {
        guard url.scheme == "http", url.user == nil, url.password == nil,
              let host = url.host, isPrivateIPv4(host), url.port == 1400 else { throw SonosError.invalidAddress }
        return try baseURL(host)
    }
}

public enum Topology {
    public static func parse(_ xml: String) throws -> [SpeakerGroup] {
        let root = try SonosXML.parse(Data(xml.utf8))
        return try root.all("ZoneGroup").compactMap { group in
            guard let id = group.attributes["ID"], let coordinator = group.attributes["Coordinator"] else { throw SonosError.invalidResponse }
            let members = group.children.filter { $0.name == "ZoneGroupMember" }
            guard let leader = members.first(where: { $0.attributes["UUID"] == coordinator }),
                  let location = leader.attributes["Location"], let leaderURL = URL(string: location) else { throw SonosError.invalidResponse }
            let coordinatorURL = try LocalAddress.origin(of: leaderURL)
            let rooms: [Room] = try members.compactMap { member in
                guard member.attributes["Invisible"] != "1", member.attributes["IsZoneBridge"] != "1" else { return nil }
                guard let uuid = member.attributes["UUID"], let name = member.attributes["ZoneName"],
                      let location = member.attributes["Location"], let url = URL(string: location) else { throw SonosError.invalidResponse }
                // ChannelMapSet identifies a bonded stereo pair; satellites are nested,
                // not independent controllable rooms. Home theatre maps use HTSatChanMapSet.
                let channelMap = member.attributes["ChannelMapSet"] ?? ""
                let paired = channelMap.contains("LF") && channelMap.contains("RF") && channelMap.contains(";")
                return Room(id: uuid, name: name, baseURL: try LocalAddress.origin(of: url), isStereoPair: paired)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return rooms.isEmpty ? nil : SpeakerGroup(id: id, coordinatorURL: coordinatorURL, rooms: rooms)
        }.sorted { ($0.rooms.first?.name ?? "") < ($1.rooms.first?.name ?? "") }
    }
}
