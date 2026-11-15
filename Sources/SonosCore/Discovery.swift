import Foundation
import Darwin

public enum SSDP {
    public static func location(from response: String) -> URL? {
        guard response.uppercased().hasPrefix("HTTP/1.1 200") else { return nil }
        for line in response.components(separatedBy: "\n") {
            let fields = line.split(separator: ":", maxSplits: 1)
            if fields.count == 2, fields[0].trimmingCharacters(in: .whitespaces).lowercased() == "location",
               let url = URL(string: fields[1].trimmingCharacters(in: .whitespacesAndNewlines)),
               (try? LocalAddress.origin(of: url)) != nil { return url }
        }
        return nil
    }
    public static func discover(seconds: TimeInterval = 3) async throws -> [URL] {
        try await Task.detached(priority: .utility) { try scan(seconds: seconds) }.value
    }
    private static func scan(seconds: TimeInterval) throws -> [URL] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { throw SonosError.network("Couldn't read your network interfaces.") }
        defer { freeifaddrs(interfaces) }
        var sockets: [Int32] = []
        var pointer = interfaces
        while let interface = pointer {
            defer { pointer = interface.pointee.ifa_next }
            let item = interface.pointee
            guard let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  item.ifa_flags & UInt32(IFF_UP) != 0,
                  item.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  item.ifa_flags & UInt32(IFF_MULTICAST) != 0 else { continue }
            let name = String(cString: item.ifa_name)
            guard !name.hasPrefix("awdl"), !name.hasPrefix("llw"), !name.hasPrefix("utun") else { continue }
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { continue }
            var local = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            local.sin_port = 0
            let bound = withUnsafePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard bound == 0 else { close(fd); continue }
            var multicastInterface = local.sin_addr
            _ = setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &multicastInterface, socklen_t(MemoryLayout<in_addr>.size))
            sockets.append(fd)
        }
        defer { sockets.forEach { close($0) } }
        guard !sockets.isEmpty else { throw SonosError.network("No accessible local network. Connect to Wi-Fi or Ethernet and allow Local Network access for Sonos Control.") }
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = UInt16(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &destination.sin_addr)
        let message = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: urn:schemas-upnp-org:device:ZonePlayer:1\r\n\r\n"
        var sent = false
        for fd in sockets {
            for _ in 0..<2 {
                let bytes = Array(message.utf8)
                let count = bytes.withUnsafeBytes { buffer in
                    withUnsafePointer(to: &destination) { target in
                        target.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                sent = sent || count > 0
            }
        }
        guard sent else { throw SonosError.network("Discovery couldn't access your network. Allow Sonos Control in System Settings → Privacy & Security → Local Network.") }
        // Any one speaker reports the whole household, so stop soon after the replies dry up.
        var results = Set<URL>()
        var deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            var descriptors = sockets.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            guard poll(&descriptors, nfds_t(descriptors.count), 100) > 0 else { continue }
            for descriptor in descriptors where descriptor.revents & Int16(POLLIN) != 0 {
                var buffer = [UInt8](repeating: 0, count: 2048)
                let count = recv(descriptor.fd, &buffer, buffer.count, 0)
                if count > 0, let url = location(from: String(decoding: buffer.prefix(count), as: UTF8.self)),
                   let origin = try? LocalAddress.origin(of: url), results.insert(origin).inserted {
                    deadline = min(deadline, Date().addingTimeInterval(0.5))
                }
            }
        }
        return results.sorted { $0.absoluteString < $1.absoluteString }
    }
}
