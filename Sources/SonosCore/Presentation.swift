import Foundation

public enum GroupPresentation {
    /// Independent of coordinator, volatile group ID, member order and IPs.
    public static func identity(_ group: SpeakerGroup) -> String {
        group.rooms.map(\.id).sorted().joined(separator: "|")
    }
    /// Rooms that differ only by a trailing number ("Study", "Study 2") share one name.
    /// Other groups are named the way the Sonos app names them.
    public static func name(_ group: SpeakerGroup) -> String {
        let names = group.rooms.map(\.name)
        let bases = names.map { $0.trimmingCharacters(in: .decimalDigits.union(.whitespaces)) }
        if names.count > 1, let base = bases.first, !base.isEmpty,
           bases.allSatisfy({ $0.caseInsensitiveCompare(base) == .orderedSame }) { return base }
        return names.count > 2 ? "\(names[0]) + \(names.count - 1)" : names.joined(separator: " + ")
    }
    public static func speakerLabel(_ room: Room) -> String {
        // "Sonos One (Gen 2)" reads better as "Sonos One".
        var model = room.model.prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces)
        if model.isEmpty || model == "Sonos" { model = room.name }
        return model + (room.isStereoPair ? " · stereo pair" : "")
    }
    public static func speakerLabel(_ room: Room, in group: SpeakerGroup) -> String {
        let label = speakerLabel(room)
        return group.rooms.filter { speakerLabel($0) == label }.count > 1 ? "\(label) · \(room.name)" : label
    }
}
