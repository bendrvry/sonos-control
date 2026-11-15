import SwiftUI
import AppKit
import SonosCore

struct SpeakerPanel: View {
    @ObservedObject var store: SpeakerStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PanelColumn {
            header
            if store.groups.isEmpty { emptyState }
            else {
                ForEach(store.ordered) { groupPanel($0) }
            }
#if BRIGHTNESS_KEYS
            if store.volumeKeysEnabled && !store.volumeKeysActive { permissionNotice }
#endif
            if let notice { errorNotice(notice) }
            if store.showConnection { connectionForm }
        }
    }

    private var notice: String? {
        store.error ?? (store.unavailable.isEmpty ? nil : "Some speakers aren't responding. Check that they're online.")
    }
    private func animate(_ change: () -> Void) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18), change)
    }

    // MARK: Header

    private var header: some View {
        PanelHeader(title: "Control", wordmark: Wordmark(text: "SONOS")) {
            if store.searching && !store.groups.isEmpty { ProgressView().controlSize(.small).scaleEffect(0.8) }
        } menu: {
            Button("Find Speakers") { Task { await store.discover(.visible) } }
            Button("Connect by IP Address…") { store.showConnection.toggle() }
            Divider()
#if BRIGHTNESS_KEYS
            if let target = store.volumeKeysTarget {
                Toggle("Brightness Keys Adjust \(GroupPresentation.name(target))" + (store.volumeKeysEnabled && !store.volumeKeysActive ? " (Needs Permission)" : ""),
                       isOn: $store.volumeKeysEnabled)
            }
#endif
            Toggle("Open at Login", isOn: $store.launchesAtLogin)
            Divider()
            Button("Quit Sonos Control") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        }
    }

    // MARK: Rooms

    @ViewBuilder private func groupPanel(_ group: SpeakerGroup) -> some View {
        Group {
            if group.rooms.count > 1 {
                let key = SpeakerStore.groupKey(group), name = GroupPresentation.name(group)
                let expanded = !store.collapsed.contains(GroupPresentation.identity(group))
                VStack(spacing: 10) {
                    VStack(spacing: 4) {
                        HStack(spacing: 7) {
                            Button { animate { store.toggleExpanded(group) } } label: {
                                HStack(spacing: 9) {
                                    DisclosureChevron(expanded: expanded)
                                    Text(name).font(.sectionTitle).lineLimit(1)
                                }.contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).help(expanded ? "Hide individual speakers" : "Show individual speakers")
                            .accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(name) speakers")
                            Spacer(minLength: 4)
                            volumeText(key, size: 17)
                            muteButton(key, name: name, size: 30)
                        }
                        slider(key, name: name, prominent: true).padding(.horizontal, 7)
                        if store.unavailable.contains(key) { unavailableLabel }
                    }
                    if expanded {
                        InsetGroup {
                            ForEach(group.rooms) { memberRow($0, label: GroupPresentation.speakerLabel($0, in: group)) }
                        }
                    }
                }
            } else if let room = group.rooms.first {
                VStack(alignment: .leading, spacing: 8) {
                    Text(room.name).font(.sectionTitle)
                    memberRow(room, label: GroupPresentation.speakerLabel(room))
                }
            }
        }
    }

    private func memberRow(_ room: Room, label: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.rowDetail).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .help("\(room.name) · \(room.model)")
                slider(room.id, name: label, prominent: false)
            }
            volumeText(room.id, size: 13).frame(minWidth: 21, alignment: .trailing)
            muteButton(room.id, name: label, size: 26)
        }
        .opacity(store.unavailable.contains(room.id) ? 0.5 : 1)
        .accessibilityElement(children: .contain)
    }

    private func slider(_ key: String, name: String, prominent: Bool) -> some View {
        ControlSlider(value: Binding(get: { Double(store.states[key]?.volume ?? 0) }, set: { store.changeVolume(key, $0) }),
                      label: "\(name) volume", isEnabled: !store.disabled(key), prominent: prominent,
                      onEditingChanged: { store.setEditing(key, $0) })
            .frame(height: prominent ? 25 : 21)
    }

    private func volumeText(_ key: String, size: CGFloat) -> some View {
        Text(store.disabled(key) ? "—" : String(store.states[key]?.volume ?? 0))
            .font(.system(size: size)).monospacedDigit()
            .foregroundStyle(store.states[key]?.muted == true ? Color.secondary : Color.primary)
    }

    private func muteButton(_ key: String, name: String, size: CGFloat) -> some View {
        let muted = store.states[key]?.muted == true
        return GlassIconButton(symbol: muted ? "speaker.slash" : "speaker.wave.2", label: "\(muted ? "Unmute" : "Mute") \(name)",
                               size: size, dimmed: muted) { store.toggleMute(key) }
            .disabled(store.disabled(key))
    }

    // MARK: Supporting states

    private var unavailableLabel: some View {
        Text("Group unavailable · try Find Speakers").font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private func errorNotice(_ text: String) -> some View {
        PanelNotice(text: text, onDismiss: store.error == nil ? nil : { store.error = nil })
    }

#if BRIGHTNESS_KEYS
    private var permissionNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "keyboard").foregroundStyle(.secondary)
                Text("To use the brightness keys, allow Sonos Control under Privacy & Security → Accessibility. They'll start working as soon as you do.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button("Open Accessibility Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(.link).font(.system(size: 11)).padding(.leading, 26)
        }
        .padding(10).insetSurface(cornerRadius: PanelMetrics.noticeRadius, hairline: false)
    }
#endif

    private var emptyState: some View {
        VStack(spacing: 10) {
            if store.searching {
                ProgressView().controlSize(.regular).padding(.top, 14).padding(.bottom, 4)
                Text("Finding your speakers…").font(.system(size: 15, weight: .semibold))
                Text("This usually takes a second or two.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Image(systemName: "hifispeaker.2.fill").font(.system(size: 30)).foregroundStyle(.secondary).padding(.top, 8)
                Text("No speakers found").font(.system(size: 15, weight: .semibold))
                Text("Check that this Mac is on the same network as your Sonos speakers, and that Local Network access is allowed.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { Task { await store.discover(.visible) } }.buttonStyle(.bordered).padding(.top, 2)
                Button("Enter a speaker's IP address") { store.showConnection = true }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity).padding(.horizontal, 12).padding(.bottom, 12)
    }

    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Connect directly").font(.system(size: 12, weight: .semibold))
            Text("Enter the IP address of any Sonos speaker. You'll find it in the Sonos app under About My System.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("192.168.1.25", text: $store.manualAddress).textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await store.discover(.manual) } }.accessibilityLabel("Speaker IP address")
                Button("Connect") { Task { await store.discover(.manual) } }.disabled(store.searching)
            }
            Button("Open Local Network Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") { NSWorkspace.shared.open(url) }
            }.buttonStyle(.link).font(.system(size: 11))
        }
        .padding(12).insetSurface(cornerRadius: 12, hairline: false)
    }
}
