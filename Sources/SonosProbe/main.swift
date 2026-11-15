import Foundation
import SonosCore

@main
struct Probe {
    static func main() async {
        do {
            let seeds: [URL]
            if let ip = CommandLine.arguments.dropFirst().first { seeds = [try LocalAddress.baseURL(ip)] }
            else { seeds = try await SSDP.discover() }
            guard !seeds.isEmpty else { throw SonosError.noSpeakers }
            let client = SonosClient()
            var seen = Set<String>()
            for seed in seeds {
                do {
                    for group in try await client.groups(at: seed) where seen.insert(group.id).inserted {
                        print("Group: \(group.rooms.map(\.name).joined(separator: ", "))")
                        for room in group.rooms {
                            let state = try await client.read(at: room.baseURL)
                            print("  \(room.name): volume \(state.volume), muted \(state.muted), stereo pair \(room.isStereoPair)")
                        }
                    }
                } catch { print("Speaker query failed: \(error.localizedDescription)") }
            }
            if seen.isEmpty { throw SonosError.noSpeakers }
            print("Read-only check completed. No speaker settings were changed.")
        } catch {
            print("Read-only check unavailable: \(error.localizedDescription)")
            exit(1)
        }
    }
}
