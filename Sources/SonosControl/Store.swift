import SwiftUI
import ServiceManagement
import SonosCore

@MainActor
final class SpeakerStore: ObservableObject {
    @Published private(set) var groups: [SpeakerGroup] = []
    @Published private(set) var states: [String: VolumeState] = [:]
    @Published private(set) var unavailable: Set<String> = []
    @Published private(set) var searching = false
    @Published private(set) var collapsed = Set(UserDefaults.standard.stringArray(forKey: "collapsedGroups") ?? [])
    @Published var error: String?
    @Published var manualAddress = UserDefaults.standard.string(forKey: "manualSpeakerIP") ?? ""
    @Published var showConnection = false
#if BRIGHTNESS_KEYS
    /// Whether the brightness keys are actually being listened to (permission granted), not just switched on.
    @Published private(set) var volumeKeysActive = false
#endif
    // Asking ServiceManagement is a synchronous call to a system service, so it's cached rather than read on every redraw.
    @Published private var opensAtLogin = SMAppService.mainApp.status == .enabled
    let isDemo: Bool

    enum Discovery { case quiet, visible, manual }
    private static let muting = "mute"

    private let client = SonosClient()
    private var seeds: [URL] = []            // one responsive speaker per household
    private var models: [String: String] = [:]
    private var poller: Task<Void, Never>?
    private var discovering = false
    private var refreshing = false
    private var syncing = false
    // The control being written (a state key, or `muting`). While set, reads never overwrite the UI.
    private var activeControl: String?
    private var editing: String?
    private var pending: Int?
    private var revision = 0
    private var lastRead = Date.distantPast
#if BRIGHTNESS_KEYS
    private lazy var volumeKeys = VolumeKeys { [weak self] in self?.nudgeVolume(by: $0) }
    private var nudge = 0
    private var nudgeReading = false
    private var keysWatcher: Task<Void, Never>?
    /// Called on every brightness key press, so the menu bar can show the volume indicator.
    var onVolumeKey: ((SpeakerGroup) -> Void)?
#endif

    init(demo: Bool = false) {
        isDemo = demo
        searching = !demo   // so a panel opened in the first instant says it's looking, not that nothing was found
        if demo { loadDemo() } else { Task { await discover() } }
#if BRIGHTNESS_KEYS
        if volumeKeysEnabled { startVolumeKeys(prompt: false) }
#endif
    }

    static func groupKey(_ group: SpeakerGroup) -> String { "group:\(group.id)" }
    /// The state that a group's one volume control reads and writes: the group's for several rooms, the room's for one.
    static func volumeKey(_ group: SpeakerGroup) -> String { group.rooms.count > 1 ? groupKey(group) : group.rooms[0].id }
    func disabled(_ key: String) -> Bool { states[key] == nil || unavailable.contains(key) }

    func toggleExpanded(_ group: SpeakerGroup) {
        collapsed.formSymmetricDifference([GroupPresentation.identity(group)])
        UserDefaults.standard.set(Array(collapsed), forKey: "collapsedGroups")
    }

    // MARK: Order

    /// Every room, with speakers grouped in the Sonos app first (they're usually the ones in use),
    /// then single rooms, each set in alphabetical order.
    var ordered: [SpeakerGroup] {
        groups.sorted { a, b in
            if (a.rooms.count > 1) != (b.rooms.count > 1) { return a.rooms.count > 1 }
            return GroupPresentation.name(a).localizedStandardCompare(GroupPresentation.name(b)) == .orderedAscending
        }
    }

#if BRIGHTNESS_KEYS
    // MARK: Volume keys

    /// The brightness keys adjust the first room at the top of the panel.
    var volumeKeysTarget: SpeakerGroup? { ordered.first }
    var volumeKeysEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "volumeKeys") }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: "volumeKeys")
            if newValue { startVolumeKeys(prompt: true) }
            else { keysWatcher?.cancel(); volumeKeys.stop(); volumeKeysActive = false }
        }
    }

    /// Without permission, keeps checking for a few minutes so the keys work as soon as it's granted,
    /// with no need to reopen the panel or relaunch.
    private func startVolumeKeys(prompt: Bool) {
        if volumeKeys.start(prompt: prompt) { volumeKeysActive = true; return }
        volumeKeysActive = false
        guard keysWatcher == nil else { return }
        keysWatcher = Task {
            for _ in 0..<150 where !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if volumeKeys.start(prompt: false) { volumeKeysActive = true; break }
            }
            keysWatcher = nil
        }
    }

    private func nudgeVolume(by step: Int) {
        guard let group = volumeKeysTarget else { return }
        let key = Self.volumeKey(group)
        onVolumeKey?(group)
        nudge += step
        guard !nudgeReading else { return }
        // A reading older than a few seconds may be stale if someone used the Sonos app in the meantime,
        // and a room that failed last time is asked again rather than left greyed out.
        let fresh = Date().timeIntervalSince(lastRead) < 3 && !unavailable.contains(key)
        if activeControl == key || isDemo || fresh { return applyNudge(key) }
        nudgeReading = true
        Task {
            apply(await readRetrying(key))
            nudgeReading = false
            applyNudge(key)
        }
    }
    private func applyNudge(_ key: String) {
        // Presses made while waiting for the speaker count, but never more than a few steps' worth.
        defer { nudge = 0 }
        guard let state = states[key] else { return }
        changeVolume(key, Double(state.volume + min(10, max(-10, nudge))))
    }

    /// macOS sometimes refuses a menu bar app's local network access for a few seconds after it has
    /// been idle ("Local network prohibited"), then allows it again. Keep asking for up to ~8 seconds
    /// instead of treating the first refusal as the speaker being offline.
    private func readRetrying(_ key: String) async -> [String: VolumeState?] {
        var values = await read([key])
        for _ in 0..<16 where values[key] ?? nil == nil {
            try? await Task.sleep(nanoseconds: 500_000_000)
            values = await read([key])
        }
        return values
    }
#endif

    var launchesAtLogin: Bool {
        get { opensAtLogin }
        set {
            do { try newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
            catch { self.error = "Couldn't change the login item. \(error.localizedDescription)" }
            opensAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: Panel lifecycle

    /// Nothing is polled while the panel is closed; opening it refreshes straight away.
    func panelDidOpen() {
        // Permission may have been granted in System Settings since the keys were switched on.
#if BRIGHTNESS_KEYS
        if volumeKeysEnabled, !volumeKeys.isRunning { startVolumeKeys(prompt: false) }
#endif
        guard !isDemo, poller == nil else { return }
        poller = Task {
            var tick = 0
            while !Task.isCancelled {
                // Grouping rarely changes, so topology is re-read on open and every 30 seconds.
                if tick % 20 == 0 { await discover() } else { await refresh() }
                tick += 1
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }
    func panelDidClose() {
        poller?.cancel()
        poller = nil
        editing = nil
    }

    // MARK: Reading

    /// Known speakers are asked for the topology first (one request). The network is only
    /// scanned when that fails, on first launch, or when the user asks.
    func discover(_ mode: Discovery = .quiet) async {
        guard !isDemo, !discovering, activeControl == nil else { return }
        discovering = true
        searching = mode != .quiet || groups.isEmpty
        defer { discovering = false; searching = false }
        do {
            var found = await topology(from: mode == .quiet ? seeds : [])
            if mode == .manual {
                found = await topology(from: [try LocalAddress.baseURL(manualAddress)])
            } else if found.seeds.isEmpty || found.seeds.count < seeds.count {
                var candidates = (try? LocalAddress.baseURL(manualAddress)).map { [$0] } ?? []
                do { candidates += try await SSDP.discover() }
                catch { if candidates.isEmpty { throw error } }
                found = await topology(from: candidates)
            }
            guard !found.groups.isEmpty else {
                if mode == .manual, !(found.error is URLError) { throw SonosError.notSonos }
                throw found.error ?? SonosError.noSpeakers
            }
            var fresh = found.groups
            await loadModels(for: fresh)
            for g in fresh.indices {
                for r in fresh[g].rooms.indices { fresh[g].rooms[r].model = models[fresh[g].rooms[r].id] ?? "Sonos" }
            }
            fresh.sort { GroupPresentation.name($0).localizedStandardCompare(GroupPresentation.name($1)) == .orderedAscending }
            // A control grabbed mid-scan keeps the topology it started with.
            guard activeControl == nil else { return }
            if fresh != groups { groups = fresh }
            seeds = found.seeds
            let valid = Set(controlKeys)
            states = states.filter { valid.contains($0.key) }
            unavailable.formIntersection(valid)
            error = nil
            if mode == .manual {
                UserDefaults.standard.set(manualAddress.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "manualSpeakerIP")
                showConnection = false
            }
            await refresh()
        } catch {
            self.error = friendly(error)
            unavailable.formUnion(states.keys)
        }
    }

    /// Queries every candidate at once and keeps one answer per household.
    private func topology(from candidates: [URL]) async -> (groups: [SpeakerGroup], seeds: [URL], error: Error?) {
        var groups: [SpeakerGroup] = [], seeds: [URL] = [], failure: Error?
        var rooms = Set<String>()
        await withTaskGroup(of: (URL, Result<[SpeakerGroup], Error>).self) { tasks in
            for seed in Set(candidates).prefix(12) {
                tasks.addTask { [client] in
                    do { return (seed, .success(try await client.groups(at: seed))) }
                    catch { return (seed, .failure(error)) }
                }
            }
            for await (seed, result) in tasks {
                switch result {
                case .success(let household):
                    let ids = household.flatMap { $0.rooms.map(\.id) }
                    guard rooms.isDisjoint(with: ids) else { continue }
                    rooms.formUnion(ids)
                    groups += household
                    seeds.append(seed)
                case .failure(let error): failure = error
                }
            }
        }
        return (groups, seeds, failure)
    }

    private func loadModels(for groups: [SpeakerGroup]) async {
        let missing = groups.flatMap(\.rooms).filter { models[$0.id] == nil }
        await withTaskGroup(of: (String, String?).self) { tasks in
            for room in missing { tasks.addTask { [client] in (room.id, try? await client.model(at: room.baseURL)) } }
            for await (id, model) in tasks { models[id] = model }
        }
    }

    func refresh() async {
        guard !isDemo, !refreshing, activeControl == nil, !groups.isEmpty else { return }
        refreshing = true
        defer { refreshing = false }
        let started = revision
        let values = await read(controlKeys)
        // A command sent while these reads were in flight is newer than they are.
        guard revision == started, activeControl == nil else { return }
        apply(values)
    }

    private var controlKeys: [String] {
        groups.flatMap { $0.rooms.map(\.id) + ($0.rooms.count > 1 ? [Self.groupKey($0)] : []) }
    }
    private func target(_ key: String) -> (URL, Bool)? {
        for group in groups {
            if key == Self.groupKey(group) { return (group.coordinatorURL, true) }
            if let room = group.rooms.first(where: { $0.id == key }) { return (room.baseURL, false) }
        }
        return nil
    }
    private func read(_ keys: [String]) async -> [String: VolumeState?] {
        await withTaskGroup(of: (String, VolumeState?).self) { tasks in
            for key in keys {
                guard let (base, group) = target(key) else { continue }
                tasks.addTask { [client] in (key, try? await client.read(at: base, group: group)) }
            }
            var values: [String: VolumeState?] = [:]
            for await (key, state) in tasks { values.updateValue(state, forKey: key) }
            return values
        }
    }
    /// Publishes only real changes, so an idle poll costs no redraw.
    private func apply(_ values: [String: VolumeState?]) {
        let valid = Set(controlKeys)
        var next = states, down = unavailable
        for (key, value) in values where valid.contains(key) {
            if let value { next[key] = value; down.remove(key) } else { down.insert(key) }
        }
        if values.values.contains(where: { $0 != nil }) { lastRead = Date() }
        if next != states { states = next }
        if down != unavailable { unavailable = down }
    }

    // MARK: Writing

    func setEditing(_ key: String, _ isEditing: Bool) { editing = isEditing ? key : nil }

    func changeVolume(_ key: String, _ value: Double) {
        guard !disabled(key), let state = states[key], activeControl == nil || activeControl == key else { return }
        let volume = min(100, max(0, Int(value.rounded())))
        guard state.volume != volume else { return }
        states[key] = VolumeState(volume: volume, muted: state.muted)
        guard !isDemo, let (base, group) = target(key) else { return }
        revision += 1
        pending = volume
        // A writer that is already running picks up `pending` on its next pass.
        guard activeControl == nil else { return }
        activeControl = key
        error = nil
        Task {
            do {
                // One snapshot per gesture keeps the speakers' relative levels.
                if group { try await client.snapshotGroup(at: base) }
                while pending != nil || editing == key {
                    if let volume = pending {
                        pending = nil
                        try await retryingRefusal { try await self.client.setVolume(at: base, group: group, volume: volume) }
                        syncRelated(to: key)
                        // At most ten requests per second, always including the final value.
                        try await Task.sleep(nanoseconds: 100_000_000)
                    } else { try await Task.sleep(nanoseconds: 30_000_000) }
                }
            } catch {
                self.error = "Couldn't change the volume. \(friendly(error))"
                pending = nil
            }
            finishWrite()
        }
    }

    func toggleMute(_ key: String) {
        guard !disabled(key), let state = states[key], activeControl == nil else { return }
        states[key] = VolumeState(volume: state.volume, muted: !state.muted)
        guard !isDemo, let (base, group) = target(key) else { return }
        revision += 1
        activeControl = Self.muting
        error = nil
        Task {
            do { try await client.setMute(at: base, group: group, muted: !state.muted) }
            catch { self.error = "Couldn't change mute. \(friendly(error))" }
            finishWrite()
        }
    }

    /// The optimistic value on screen is replaced by what the speakers report.
    private func finishWrite() {
        revision += 1
        editing = nil
        activeControl = nil
        Task { await refresh() }
    }

    /// Moving a group moves its members (and the reverse), so follow along during a drag.
    private func syncRelated(to key: String) {
        guard !syncing, let group = groups.first(where: { group in
            group.rooms.count > 1 && (Self.groupKey(group) == key || group.rooms.contains { $0.id == key })
        }) else { return }
        let keys = (group.rooms.map(\.id) + [Self.groupKey(group)]).filter { $0 != key && !unavailable.contains($0) }
        syncing = true
        Task {
            let values = await read(keys)
            syncing = false
            if activeControl == key { apply(values) }
        }
    }

    /// Repeats a write while macOS is briefly refusing local network access (it can happen after the
    /// app has been idle for a while, and clears by itself within a few seconds).
    private func retryingRefusal(_ write: () async throws -> Void) async throws {
        for attempt in 0..<16 {
            do { return try await write() }
            catch let error as URLError where error.code == .notConnectedToInternet && attempt < 15 {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func friendly(_ error: Error) -> String {
        if let error = error as? URLError, [.notConnectedToInternet, .cannotConnectToHost, .timedOut].contains(error.code) {
            return "Check that the speaker is online and Local Network access is allowed for Sonos Control."
        }
        return error.localizedDescription
    }

    // MARK: Demo

    /// Sample rooms for screenshots and UI work (`--demo`). Nothing is sent to real speakers.
    private func loadDemo() {
        let base = URL(string: "http://192.168.1.10:1400")!
        func room(_ id: String, _ name: String, _ model: String, pair: Bool = false) -> Room {
            Room(id: id, name: name, baseURL: base, isStereoPair: pair, model: model)
        }
        func single(_ id: String, _ name: String, _ model: String) -> SpeakerGroup {
            SpeakerGroup(id: id, coordinatorURL: base, rooms: [room(id, name, model)])
        }
        let living = SpeakerGroup(id: "living", coordinatorURL: base, rooms: [
            room("living-1", "Living Room", "Sonos Arc"), room("living-2", "Living Room 2", "Sonos Era 100", pair: true)
        ])
        groups = [single("kitchen", "Kitchen", "Sonos Era 100"), living, single("office", "Office", "Sonos Move")]
        states = ["living-1": VolumeState(volume: 40, muted: false), "living-2": VolumeState(volume: 56, muted: false),
                  Self.groupKey(living): VolumeState(volume: 48, muted: false),
                  "kitchen": VolumeState(volume: 22, muted: false), "office": VolumeState(volume: 30, muted: true)]
        // `--demo-many` adds enough rooms to run past the bottom of the screen, to check scrolling.
        if CommandLine.arguments.contains("--demo-many") {
            for (index, name) in ["Bathroom", "Dining Room", "Garage", "Garden", "Gym", "Hallway", "Landing", "Library",
                                  "Loft", "Nursery", "Patio", "Playroom", "Porch", "Spare Room", "Studio", "Utility",
                                  "Annexe", "Attic", "Balcony", "Cellar", "Conservatory", "Den", "Lounge", "Pantry",
                                  "Sauna", "Shed", "Snug", "Terrace"].enumerated() {
                let id = "extra-\(index)"
                groups.append(single(id, name, index.isMultiple(of: 2) ? "Sonos Era 100" : "Sonos One"))
                states[id] = VolumeState(volume: 10 + index * 4, muted: false)
            }
        }
    }
}
