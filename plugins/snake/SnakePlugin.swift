import AppKit
import SwiftUI
import AVFoundation
import OnecastPluginKit

/// A quick, old-school Snake game as a native SwiftUI plugin. Surface-only — there is no root row
/// list, the launcher row opens straight into the board. Arrow keys steer via `PluginListKey`,
/// Return starts / pauses / resumes / restarts, all handled through `PluginScaffold`.
final class SnakePlugin: NSObject, OnecastPlugin {
    static let metadata = PluginMetadata(
        name: "Snake",
        subtitle: "Retro snake, right in the palette",
        icon: "gamecontroller.fill")

    override init() { super.init() }

    func rootSurface(context: PluginContext) -> AnyView? {
        AnyView(SnakeBoard())
    }
}

// MARK: - Model

private struct GridPoint: Hashable {
    var x: Int
    var y: Int
}

private enum Direction {
    case up, down, left, right

    var delta: (dx: Int, dy: Int) {
        switch self {
        case .up: return (0, -1)
        case .down: return (0, 1)
        case .left: return (-1, 0)
        case .right: return (1, 0)
        }
    }

    /// Only reversals are illegal (running straight into your own neck) — same-direction and
    /// perpendicular turns are always allowed.
    func isReversal(of other: Direction) -> Bool {
        switch (self, other) {
        case (.up, .down), (.down, .up), (.left, .right), (.right, .left): return true
        default: return false
        }
    }
}

private enum RunState: Equatable {
    case ready, playing, paused, over
}

// MARK: - Sound

/// A tiny synthesized square-wave beeper for retro feedback — no audio assets. Each `play` builds
/// an in-memory 16-bit PCM WAV and hands it to a fresh `AVAudioPlayer`; that's the plain "play this
/// sound" API (vs. wiring an `AVAudioEngine` graph by hand), so there's no engine/mixer connection
/// format to get wrong. Held as `@State` on the view so the same instance survives SwiftUI
/// re-rendering the view struct.
private final class RetroBeeper {
    private let sampleRate: Double = 44_100
    /// Keeps each player alive until it finishes — an `AVAudioPlayer` stops the moment it's
    /// deallocated, and back-to-back beeps (e.g. the game-over jingle) overlap several at once.
    private var activePlayers: [AVAudioPlayer] = []

    func play(frequency: Double, duration: Double, volume: Float = 0.4) {
        guard let data = wavData(frequency: frequency, duration: duration),
            let player = try? AVAudioPlayer(data: data)
        else { return }
        player.volume = volume
        player.prepareToPlay()
        activePlayers.append(player)
        player.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.25) { [weak self, weak player] in
            guard let self, let player else { return }
            self.activePlayers.removeAll { $0 === player }
        }
    }

    /// Plays notes back to back rather than at once — each `play` spins up its own
    /// `AVAudioPlayer`, so firing several with no delay between them stacks them into one
    /// simultaneous (and misleadingly loud) burst instead of the intended run of distinct notes.
    func playSequence(_ notes: [(frequency: Double, duration: Double)], volume: Float = 0.4) {
        var offset: Double = 0
        for note in notes {
            DispatchQueue.main.asyncAfter(deadline: .now() + offset) { [weak self] in
                self?.play(frequency: note.frequency, duration: note.duration, volume: volume)
            }
            offset += note.duration
        }
    }

    private func wavData(frequency: Double, duration: Double) -> Data? {
        let frameCount = Int(sampleRate * duration)
        guard frameCount > 0 else { return nil }
        let period = sampleRate / frequency
        // A short attack/release ramp avoids an audible click at the buffer's edges.
        let ramp = max(1, min(Int(sampleRate * 0.005), frameCount / 4))
        var samples = [Int16](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            let phase = Double(frame).truncatingRemainder(dividingBy: period) / period
            var amplitude = phase < 0.5 ? 1.0 : -1.0
            if frame < ramp { amplitude *= Double(frame) / Double(ramp) }
            let tail = frameCount - frame
            if tail < ramp { amplitude *= Double(tail) / Double(ramp) }
            samples[frame] = Int16(amplitude * Double(Int16.max) * 0.85)
        }
        return wavContainer(samples: samples, sampleRate: Int(sampleRate))
    }

    /// Wraps raw mono 16-bit PCM samples in a minimal WAV (RIFF) header — the one format every
    /// `AVAudioPlayer` reads without needing a bundled asset.
    private func wavContainer(samples: [Int16], sampleRate: Int) -> Data {
        let bitsPerSample: UInt16 = 16
        let channels: UInt16 = 1
        let byteRate = UInt32(sampleRate * Int(channels) * Int(bitsPerSample) / 8)
        let blockAlign = UInt16(Int(channels) * Int(bitsPerSample) / 8)
        let dataSize = UInt32(samples.count * 2)

        var data = Data()
        func appendASCII(_ s: String) { data.append(contentsOf: s.utf8) }
        func appendLE32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func appendLE16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        appendASCII("RIFF")
        appendLE32(36 + dataSize)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendLE32(16)
        appendLE16(1) // PCM
        appendLE16(channels)
        appendLE32(UInt32(sampleRate))
        appendLE32(byteRate)
        appendLE16(blockAlign)
        appendLE16(bitsPerSample)
        appendASCII("data")
        appendLE32(dataSize)
        for sample in samples { appendLE16(UInt16(bitPattern: sample)) }
        return data
    }
}

// MARK: - Board

private struct SnakeBoard: View {
    static let cols = 22
    static let rows = 14
    private static let highScoreKey = "com.sujha.snake.highScore"
    private static let soundKey = "com.sujha.snake.soundEnabled"
    private static let startInterval = 0.16
    private static let minInterval = 0.07

    @State private var snake: [GridPoint] = []
    @State private var direction: Direction = .right
    @State private var pendingDirection: Direction = .right
    @State private var food = GridPoint(x: 0, y: 0)
    @State private var runState: RunState = .ready
    @State private var score = 0
    @State private var highScore = UserDefaults.standard.integer(forKey: SnakeBoard.highScoreKey)
    @State private var tickInterval = SnakeBoard.startInterval
    @State private var navigator = PluginNavigator()
    @State private var soundEnabled = UserDefaults.standard.object(forKey: SnakeBoard.soundKey) as? Bool ?? true
    @State private var beeper = RetroBeeper()

    var body: some View {
        PluginScaffold(
            navigator: navigator,
            primaryActionLabel: primaryLabel,
            commands: currentCommands,
            commandTitle: { "Snake" },
            listKey: handleListKey
        ) {
            gameBody
        }
    }

    private var gameBody: some View {
        VStack(spacing: 14) {
            header
            board
            hint
        }
        .padding(20)
        .padding(.bottom, 34)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .task(id: runState) { await runLoop() }
    }

    private var header: some View {
        HStack {
            Text("SCORE \(pad(score))")
            Spacer()
            Image(systemName: soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 11))
            Text("HI \(pad(highScore))")
        }
        .font(.system(.body, design: .monospaced).bold())
        .foregroundColor(.green)
    }

    private var hint: some View {
        Text("↑ ↓ ← → steer  ·  ↵ \(primaryLabel.lowercased())")
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.green.opacity(0.55))
    }

    private var board: some View {
        GeometryReader { geo in
            let cell = min(geo.size.width / CGFloat(Self.cols), geo.size.height / CGFloat(Self.rows))
            let boardSize = CGSize(width: cell * CGFloat(Self.cols), height: cell * CGFloat(Self.rows))
            ZStack {
                Canvas { context, _ in
                    context.stroke(
                        Path(CGRect(origin: .zero, size: boardSize).insetBy(dx: 0.5, dy: 0.5)),
                        with: .color(.green.opacity(0.45)), lineWidth: 1)

                    let foodRect = CGRect(
                        x: CGFloat(food.x) * cell, y: CGFloat(food.y) * cell, width: cell, height: cell
                    ).insetBy(dx: cell * 0.2, dy: cell * 0.2)
                    context.fill(Path(ellipseIn: foodRect), with: .color(.red))

                    for (index, segment) in snake.enumerated() {
                        let rect = CGRect(
                            x: CGFloat(segment.x) * cell, y: CGFloat(segment.y) * cell,
                            width: cell, height: cell
                        ).insetBy(dx: cell * 0.08, dy: cell * 0.08)
                        context.fill(
                            Path(rect), with: .color(index == 0 ? .green : .green.opacity(0.75)))
                    }
                }
                .frame(width: boardSize.width, height: boardSize.height)

                if runState != .playing {
                    overlay.frame(width: boardSize.width, height: boardSize.height)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var overlay: some View {
        ZStack {
            Color.black.opacity(0.72)
            VStack(spacing: 8) {
                Text(overlayTitle)
                    .font(.system(.title2, design: .monospaced).bold())
                Text(overlaySubtitle)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundColor(.green.opacity(0.8))
            }
            .foregroundColor(.green)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
        }
    }

    private var overlayTitle: String {
        switch runState {
        case .ready: return "SNAKE"
        case .paused: return "PAUSED"
        case .over: return "GAME OVER"
        case .playing: return ""
        }
    }

    private var overlaySubtitle: String {
        switch runState {
        case .ready: return "Press ↵ to start"
        case .paused: return "Press ↵ to resume"
        case .over: return "Score \(score) · Press ↵ to play again"
        case .playing: return ""
        }
    }

    private var primaryLabel: String {
        switch runState {
        case .ready: return "Start"
        case .playing: return "Pause"
        case .paused: return "Resume"
        case .over: return "Play Again"
        }
    }

    private func currentCommands() -> [PluginCommand] {
        [
            PluginCommand(
                title: "New Game", subtitle: "Reset the board", icon: .symbol("arrow.counterclockwise"),
                shortcut: "⌘N", action: { reset() }),
            PluginCommand(
                title: soundEnabled ? "Mute Sound" : "Unmute Sound", subtitle: nil,
                icon: .symbol(soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill"),
                shortcut: "⌘M", action: { toggleSound() }),
        ]
    }

    // MARK: Input

    private func handleListKey(_ key: PluginListKey) -> Bool {
        switch key {
        case .up: return turn(.up)
        case .down: return turn(.down)
        case .left: return turn(.left)
        case .right: return turn(.right)
        case .submit:
            switch runState {
            case .ready, .over: reset()
            case .playing: runState = .paused
            case .paused: runState = .playing
            }
            return true
        @unknown default:
            return false
        }
    }

    /// Steering only applies while running; a reversal is silently dropped (it would just kill the
    /// snake on itself) rather than treated as a no-op key, so it never leaks to another handler.
    private func turn(_ newDirection: Direction) -> Bool {
        guard runState == .playing else { return true }
        guard !newDirection.isReversal(of: direction) else { return true }
        pendingDirection = newDirection
        return true
    }

    private func toggleSound() {
        soundEnabled.toggle()
        UserDefaults.standard.set(soundEnabled, forKey: Self.soundKey)
        if soundEnabled { beeper.play(frequency: 660, duration: 0.05) }
    }

    // MARK: Game loop

    private func runLoop() async {
        guard runState == .playing else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(Int(tickInterval * 1000)))
            if Task.isCancelled { return }
            guard runState == .playing else { return }
            tick()
        }
    }

    private func reset() {
        let midY = Self.rows / 2
        snake = [GridPoint(x: 5, y: midY), GridPoint(x: 4, y: midY), GridPoint(x: 3, y: midY)]
        direction = .right
        pendingDirection = .right
        score = 0
        tickInterval = Self.startInterval
        food = randomFood()
        runState = .playing
        if soundEnabled { beeper.play(frequency: 660, duration: 0.05) }
    }

    private func tick() {
        direction = pendingDirection
        let head = snake[0]
        let delta = direction.delta
        let newHead = GridPoint(x: head.x + delta.dx, y: head.y + delta.dy)

        guard newHead.x >= 0, newHead.x < Self.cols, newHead.y >= 0, newHead.y < Self.rows,
            !snake.contains(newHead)
        else {
            runState = .over
            if soundEnabled {
                beeper.playSequence([(220, 0.12), (160, 0.12), (110, 0.18)])
            }
            return
        }

        snake.insert(newHead, at: 0)
        if newHead == food {
            score += 1
            if score > highScore {
                highScore = score
                UserDefaults.standard.set(highScore, forKey: Self.highScoreKey)
            }
            tickInterval = max(Self.minInterval, tickInterval - 0.004)
            food = randomFood()
            if soundEnabled { beeper.playSequence([(988, 0.05), (1318, 0.07)], volume: 0.45) }
        } else {
            snake.removeLast()
        }
    }

    private func randomFood() -> GridPoint {
        var candidate: GridPoint
        repeat {
            candidate = GridPoint(x: Int.random(in: 0..<Self.cols), y: Int.random(in: 0..<Self.rows))
        } while snake.contains(candidate)
        return candidate
    }

    private func pad(_ value: Int) -> String { String(format: "%03d", value) }
}

// MARK: - Entry point

/// The loader handshake: the host `dlsym`s this symbol, calls it once on the main thread, and casts
/// the result to `OnecastPlugin`. Every plugin exports exactly this.
@_cdecl("onecastPluginCreate")
public func onecastPluginCreate() -> UnsafeMutableRawPointer {
    OnecastPluginRuntime.export { SnakePlugin() }
}
