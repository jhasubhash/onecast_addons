import CoreAudio
import Observation
import OnecastPluginKit
import SwiftUI

// MARK: - CoreAudio helpers

private let systemObject = AudioObjectID(kAudioObjectSystemObject)
/// `kAudioHardwareServiceDeviceProperty_VirtualMainVolume`, which lives in a deprecated header.
private let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663  // 'vmvc'

private func address(
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

private func read<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, as zero: T) -> T? {
    var addr = addr
    var value = zero
    var size = UInt32(MemoryLayout<T>.size)
    let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
    return status == noErr ? value : nil
}

private func write<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ value: T) {
    var addr = addr
    var value = value
    AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &value)
}

/// The address(es) that control a device: one main-element property, else one per channel.
private func controls(
    _ device: AudioObjectID, scope: AudioObjectPropertyScope,
    main: [AudioObjectPropertySelector], channel: AudioObjectPropertySelector
) -> [AudioObjectPropertyAddress] {
    for selector in main {
        var a = address(selector, scope)
        if AudioObjectHasProperty(device, &a) { return [a] }
    }
    return [AudioObjectPropertyElement(1), 2].compactMap { element in
        var a = address(channel, scope, element)
        return AudioObjectHasProperty(device, &a) ? a : nil
    }
}

private func volumeControls(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [AudioObjectPropertyAddress] {
    controls(device, scope: scope, main: [virtualMainVolume, kAudioDevicePropertyVolumeScalar],
             channel: kAudioDevicePropertyVolumeScalar)
}

private func muteControls(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [AudioObjectPropertyAddress] {
    controls(device, scope: scope, main: [kAudioDevicePropertyMute], channel: kAudioDevicePropertyMute)
}

private func makeListener(_ handler: @escaping @Sendable () -> Void) -> AudioObjectPropertyListenerBlock {
    { _, _ in handler() }
}

/// Applies volume and mute off the main thread, keeping only the newest value per control, so a
/// slider drag is never a queue of blocking Core Audio writes.
private final class ControlWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "audio-devices.write")
    private let lock = NSLock()
    private var pending: [String: () -> Void] = [:]
    private var running = false

    func submit(_ key: String, _ job: @escaping () -> Void) {
        lock.lock()
        pending[key] = job
        let start = !running
        running = true
        lock.unlock()
        guard start else { return }
        queue.async { [self] in
            while true {
                lock.lock()
                guard let key = pending.keys.first, let job = pending.removeValue(forKey: key) else {
                    running = false
                    lock.unlock()
                    return
                }
                lock.unlock()
                job()
            }
        }
    }
}

// MARK: - Model

struct AudioDev: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let transport: UInt32

    var icon: String {
        let lower = name.lowercased()
        let personal = ["airpods", "headphone", "headset", "buds", "beats", "wh-", "wf-", "bose", "jabra"]
        if personal.contains(where: lower.contains) { return "headphones" }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return lower.contains("mic") ? "mic.fill" : "laptopcomputer"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeUSB: return lower.contains("mic") ? "mic.fill" : "cable.connector"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "waveform"
        default: return "speaker.wave.2.fill"
        }
    }
}

enum AudioDirection {
    case output, input

    var scope: AudioObjectPropertyScope {
        self == .output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput
    }
    var defaultSelector: AudioObjectPropertySelector {
        self == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
    }
}

/// One direction's state: its devices, the default one and that one's volume and mute.
struct AudioSide: Equatable {
    var devices: [AudioDev] = []
    var current: AudioDev?
    var volume: Double = 0
    var hasVolume = false
    var muted = false
    var hasMute = false
}

/// Core Audio reads. Each is a round trip to coreaudiod, so none belongs on the main thread.
private enum AudioReader {
    static func devices() -> [AudioDev] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let name = (read(id, address(kAudioObjectPropertyName), as: Optional<CFString>.none) ?? nil) as String? ?? ""
            // Core Audio's own scratch aggregate for the default device is not something to pick.
            guard !name.isEmpty, !name.hasPrefix("CADefaultDeviceAggregate") else { return nil }
            let transport = read(id, address(kAudioDevicePropertyTransportType), as: UInt32(0)) ?? 0
            return AudioDev(id: id, name: name, transport: transport)
        }
    }

    static func hasStreams(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Bool {
        var a = address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr && size > 0
    }

    /// The whole side: its devices, the default one, and that one's levels.
    static func side(_ direction: AudioDirection, _ all: [AudioDev]) -> AudioSide {
        var s = AudioSide()
        s.devices = all.filter { hasStreams($0.id, direction.scope) }
        let defaultID = read(systemObject, address(direction.defaultSelector), as: AudioDeviceID(0)) ?? 0
        s.current = s.devices.first { $0.id == defaultID }
        return levels(s, direction)
    }

    /// Only the default device's volume and mute: what a level notification can have changed.
    static func levels(_ side: AudioSide, _ direction: AudioDirection) -> AudioSide {
        var s = side
        guard let device = s.current else { return s }
        let volumes = volumeControls(device.id, direction.scope).compactMap { read(device.id, $0, as: Float32(0)) }
        s.hasVolume = !volumes.isEmpty
        s.volume = volumes.isEmpty ? 0 : Double(volumes.reduce(0, +)) / Double(volumes.count)
        let mutes = muteControls(device.id, direction.scope).compactMap { read(device.id, $0, as: UInt32(0)) }
        s.hasMute = !mutes.isEmpty
        s.muted = mutes.contains { $0 != 0 }
        return s
    }
}

@MainActor
@Observable
final class AudioModel {
    private(set) var output = AudioSide()
    private(set) var input = AudioSide()

    @ObservationIgnored private var structureListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var levelListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var watched: [(AudioObjectID, AudioObjectPropertyAddress)] = []
    @ObservationIgnored private var watchedIDs: [AudioDeviceID?] = []
    @ObservationIgnored private let writer = ControlWriter()
    /// Until when a notification's read-back is stale: it may predate the user's last slider move.
    @ObservationIgnored private var localEdit: [Bool: Date] = [:]
    @ObservationIgnored private var scheduled = false
    @ObservationIgnored private var wantsFull = false

    private static let systemSelectors = [
        kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultInputDevice,
    ]

    func start() {
        guard structureListener == nil else { return }
        let structure = makeListener { [weak self] in
            Task { @MainActor in self?.schedule(full: true) }
        }
        levelListener = makeListener { [weak self] in
            Task { @MainActor in self?.schedule(full: false) }
        }
        structureListener = structure
        for selector in Self.systemSelectors {
            var a = address(selector)
            AudioObjectAddPropertyListenerBlock(systemObject, &a, .main, structure)
        }
        schedule(full: true)
    }

    func stop() {
        guard let structure = structureListener else { return }
        for selector in Self.systemSelectors {
            var a = address(selector)
            AudioObjectRemovePropertyListenerBlock(systemObject, &a, .main, structure)
        }
        unwatch()
        structureListener = nil
        levelListener = nil
    }

    func select(_ device: AudioDev, _ direction: AudioDirection) {
        output.current = direction == .output ? device : output.current
        input.current = direction == .input ? device : input.current
        let selector = direction.defaultSelector
        writer.submit("select-\(direction == .output)") {
            write(systemObject, address(selector), device.id)
            if direction == .output {
                write(systemObject, address(kAudioHardwarePropertyDefaultSystemOutputDevice), device.id)
            }
        }
        schedule(full: true)
    }

    func setVolume(_ value: Double, _ direction: AudioDirection) {
        guard let device = side(direction).current else { return }
        localEdit[direction == .output] = Date()
        if direction == .output { output.volume = value } else { input.volume = value }
        let scope = direction.scope
        writer.submit("v\(device.id)-\(direction == .output)") {
            for a in volumeControls(device.id, scope) { write(device.id, a, Float32(value)) }
        }
        // Raising the volume of a muted device is meant to unmute it.
        if value > 0, side(direction).muted { setMuted(false, direction) }
    }

    func setMuted(_ muted: Bool, _ direction: AudioDirection) {
        guard let device = side(direction).current else { return }
        localEdit[direction == .output] = Date()
        if direction == .output { output.muted = muted } else { input.muted = muted }
        let scope = direction.scope
        writer.submit("m\(device.id)-\(direction == .output)") {
            for a in muteControls(device.id, scope) { write(device.id, a, UInt32(muted ? 1 : 0)) }
        }
    }

    func side(_ direction: AudioDirection) -> AudioSide { direction == .output ? output : input }

    // MARK: Reading

    /// A drag makes coreaudiod send a burst of notifications; take one reading for the burst.
    private func schedule(full: Bool) {
        wantsFull = wantsFull || full
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            await self?.reload()
        }
    }

    private func reload() async {
        scheduled = false
        let full = wantsFull
        wantsFull = false
        let (oldOut, oldIn) = (output, input)
        let (newOut, newIn) = await Task.detached { () -> (AudioSide, AudioSide) in
            if full {
                let all = AudioReader.devices()
                return (AudioReader.side(.output, all), AudioReader.side(.input, all))
            }
            return (AudioReader.levels(oldOut, .output), AudioReader.levels(oldIn, .input))
        }.value
        guard structureListener != nil else { return }
        apply(newOut, .output)
        apply(newIn, .input)
        _ = (oldOut, oldIn)
        let ids = [output.current?.id, input.current?.id]
        if ids != watchedIDs {
            watchedIDs = ids
            rewatch()
        }
    }

    private func apply(_ reading: AudioSide, _ direction: AudioDirection) {
        var s = reading
        let current = side(direction)
        // Keep what the user just set; the device reports it back a moment later.
        if let t = localEdit[direction == .output], Date().timeIntervalSince(t) < 0.5,
           s.current == current.current {
            s.volume = current.volume
            s.muted = current.muted
        }
        guard s != current else { return }
        if direction == .output { output = s } else { input = s }
    }

    // MARK: Watching the default devices' volume and mute

    private func unwatch() {
        guard let block = levelListener else { return }
        for (object, var a) in watched { AudioObjectRemovePropertyListenerBlock(object, &a, .main, block) }
        watched = []
    }

    private func rewatch() {
        guard let block = levelListener else { return }
        unwatch()
        for (direction, s) in [(AudioDirection.output, output), (.input, input)] {
            guard let device = s.current else { continue }
            for var a in volumeControls(device.id, direction.scope) + muteControls(device.id, direction.scope) {
                AudioObjectAddPropertyListenerBlock(device.id, &a, .main, block)
                watched.append((device.id, a))
            }
        }
    }
}

// MARK: - Widget

/// The active headphones (output) and microphone (input) on the dock; the popover lists every
/// device of each kind to switch to, with volume and mute.
final class AudioDevicesWidget: OnecastDockWidget {
    static let metadata = DockWidgetMetadata(
        name: "Audio Devices",
        subtitle: "Active headphones and microphone",
        icon: "headphones",
        category: "System",
        sizes: [.compact, .wide])

    private let model = AudioModel()

    required init() {
        model.start()
    }

    func tile(context: DockWidgetContext) -> AnyView {
        AnyView(AudioTile(model: model, context: context))
    }

    func popover(context: DockWidgetContext) -> AnyView? {
        AnyView(AudioPopover(model: model, context: context))
    }

    func didRemove() {
        model.stop()
    }
}

private func outputIcon(_ s: AudioSide) -> String {
    if s.muted { return "speaker.slash.fill" }
    return s.current?.icon ?? "speaker.slash"
}

private func inputIcon(_ s: AudioSide) -> String {
    s.muted || s.current == nil ? "mic.slash.fill" : "mic.fill"
}

private struct AudioTile: View {
    let model: AudioModel
    let context: DockWidgetContext

    var body: some View {
        Group {
            if context.size == .compact {
                // Two glyphs stacked, or side by side on a bottom dock, whichever the tile suits.
                VStack(spacing: context.tileLength * 0.08) {
                    glyph(outputIcon(model.output), muted: model.output.muted || model.output.current == nil)
                    glyph(inputIcon(model.input), muted: model.input.muted || model.input.current == nil)
                }
            } else {
                // A side dock is narrow and tall, so a wide tile stacks its two rows.
                let layout = context.edge.isVertical
                    ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 12))
                layout {
                    row(outputIcon(model.output), model.output)
                    row(inputIcon(model.input), model.input)
                }
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func glyph(_ symbol: String, muted: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: context.tileLength * 0.3))
            .foregroundStyle(muted ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
            .frame(height: context.tileLength * 0.32)
    }

    private func row(_ symbol: String, _ s: AudioSide) -> some View {
        let muted = s.muted || s.current == nil
        return HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: context.tileLength * 0.26))
                .foregroundStyle(muted ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
            Text(s.current?.name ?? "None")
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: context.edge.isVertical ? nil : 80, alignment: .leading)
        }
    }
}

private struct AudioPopover: View {
    let model: AudioModel
    let context: DockWidgetContext

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("Output", "Headphones & speakers", .output)
            Divider()
            section("Input", "Microphone", .input)
            Divider()
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                    context.actions.openURL(url)
                }
                context.actions.closePopover()
            } label: {
                Label("Sound Settings", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 300)
    }

    private func section(_ title: String, _ subtitle: String, _ direction: AudioDirection) -> some View {
        let s = model.side(direction)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            if s.hasVolume || s.hasMute {
                HStack(spacing: 8) {
                    Button {
                        model.setMuted(!s.muted, direction)
                    } label: {
                        Image(systemName: direction == .output
                              ? (s.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                              : (s.muted ? "mic.slash.fill" : "mic.fill"))
                            .foregroundStyle(s.muted ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                            .frame(width: 20)
                    }
                    .buttonStyle(.plain)
                    .disabled(!s.hasMute)
                    Slider(value: Binding(get: { s.volume }, set: { model.setVolume($0, direction) }), in: 0...1)
                        .disabled(!s.hasVolume)
                    Text("\(Int((s.volume * 100).rounded()))%")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
            if s.devices.isEmpty {
                Text("No devices").font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 2) {
                ForEach(s.devices) { device in
                    DeviceRow(device: device, active: device.id == s.current?.id) {
                        model.select(device, direction)
                    }
                }
            }
        }
    }
}

private struct DeviceRow: View {
    let device: AudioDev
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: device.icon).frame(width: 18)
                Text(device.name).lineLimit(1)
                Spacer(minLength: 4)
                if active { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .font(.callout)
            .fontWeight(active ? .semibold : .regular)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(active ? 0.12 : hovering ? 0.07 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The host `dlsym`s this symbol and calls it once per instance, on the main thread.
@_cdecl("onecastDockWidgetCreate")
public func onecastDockWidgetCreate() -> UnsafeMutableRawPointer {
    OnecastDockWidgetRuntime.export { AudioDevicesWidget() }
}
