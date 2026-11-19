import AppKit
import Foundation
import Observation
import OnecastPluginKit

// MARK: - Settings

/// The manifest's preferences, read fresh each time so an edit in Settings applies at once.
@MainActor
enum Settings {
    static let pluginID = "com.sujha.imagegen"
    private static let prefs = PluginPreferences(pluginID: pluginID)

    static var outputFolder: URL {
        let raw = prefs.string("outputFolder") ?? "~/Pictures/ImageGen"
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
    }
    static var showProgress: Bool { prefs.bool("showProgress") }
    static var showCard: Bool { prefs.bool("showCard") }
    static var closeOnGenerate: Bool { prefs.bool("closeOnGenerate") }
    static var safeMode: Bool { prefs.bool("safeMode") }
    static var saveSettings: Bool { prefs.bool("saveSettings") }
    static var serverURL: URL { URL(string: prefs.string("serverURL") ?? "http://127.0.0.1:8189") ?? URL(string: "http://127.0.0.1:8189")! }
    static var modelsFolder: URL {
        URL(fileURLWithPath: ((prefs.string("modelsFolder") ?? "~/Documents/comfyui/models") as NSString).expandingTildeInPath)
    }
    static var startCommand: String {
        prefs.string("startCommand") ?? "python3 -I ~/Developer/jarvis/engine/comfy.py serve"
    }

    /// Where Jarvis keeps its accounts' looks.json, for the style presets.
    static var looksRoot: URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Jarvis/accounts")
        return FileManager.default.fileExists(atPath: root.path) ? root : nil
    }

    /// What the form chose last, so the next open starts there.
    static func remembered(_ name: String) -> String? { prefs.string("last.\(name)") }
    static func remember(_ value: String?, _ name: String) { prefs.set(value, for: "last.\(name)") }
}

// MARK: - Jobs

/// The sampler's position, shared between the socket listener and the polling loop.
@MainActor
final class StepTracker {
    var step = (0, 0)
    var since: Date?
}

enum JobState: String, Codable, Sendable {
    case queued, running, done, failed, cancelled
}

struct Job: Identifiable, Codable, Sendable {
    let id: UUID
    var request: GenerationRequest
    let created: Date
    var state: JobState = .queued
    var outputs: [String] = []
    var seeds: [Int] = []
    var error: String?
    var finished: Date?
    var seconds: Double?

    var outputURLs: [URL] { outputs.map { URL(fileURLWithPath: $0) } }
    var isActive: Bool { state == .queued || state == .running }
}

/// What a running job is doing right now. Not persisted.
struct LiveProgress: Equatable {
    var phase: String
    /// 0...1 across every image of the job, nil while nothing measurable is happening.
    var fraction: Double?
    var remaining: TimeInterval?
}

/// Every generation, run one at a time in the background. One per loaded plugin image, so a job
/// outlives the palette closing: the host drops the plugin object, not the code it was built from.
@MainActor
@Observable
final class JobCenter {
    static let shared = JobCenter()

    private(set) var jobs: [Job] = []
    private(set) var live: [UUID: LiveProgress] = [:]
    private(set) var catalog = Catalog()
    private(set) var catalogLoaded = false

    @ObservationIgnored var services: OnecastHostServices?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var cancelled: Set<UUID> = []
    @ObservationIgnored private var activePrompt: (job: UUID, prompt: String, client: ComfyClient)?
    @ObservationIgnored private var lastHUD: (String, Int)?
    /// Seconds one image took, by model and resolution, for the time-left estimate.
    @ObservationIgnored private var timings: [String: Double] = [:]

    private init() {
        load()
    }

    // MARK: Catalog

    func refreshCatalog() {
        let models = Settings.modelsFolder
        let looks = Settings.looksRoot
        Task {
            let scanned = await Task.detached(priority: .userInitiated) {
                Catalog.scan(modelsRoot: models, looksRoot: looks)
            }.value
            catalog = scanned
            catalogLoaded = true
        }
    }

    // MARK: Queue

    func enqueue(_ request: GenerationRequest) {
        jobs.insert(Job(id: UUID(), request: request, created: Date()), at: 0)
        save()
        pump()
    }

    func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].isActive else { return }
        cancelled.insert(id)
        if jobs[index].state == .queued {
            jobs[index].state = .cancelled
            jobs[index].finished = Date()
            save()
        } else if let active = activePrompt, active.job == id {
            Task { await active.client.cancel(active.prompt) }
        }
    }

    func cancelAll() {
        for job in jobs where job.isActive { cancel(job.id) }
    }

    func remove(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), !job.isActive else { return }
        jobs.removeAll { $0.id == id }
        save()
    }

    func clearFinished() {
        jobs.removeAll { !$0.isActive }
        save()
    }

    var running: Job? { jobs.first { $0.state == .running } }
    var queuedCount: Int { jobs.filter { $0.state == .queued }.count }

    private func pump() {
        guard worker == nil, let next = jobs.last(where: { $0.state == .queued }) else { return }
        worker = Task { [weak self] in
            await self?.run(next.id)
            self?.worker = nil
            self?.pump()
        }
    }

    // MARK: Running one job

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    private func report(_ id: UUID, _ phase: String, fraction: Double? = nil, remaining: TimeInterval? = nil) {
        let progress = LiveProgress(phase: phase, fraction: fraction, remaining: remaining)
        guard live[id] != progress else { return }
        live[id] = progress
        guard Settings.showProgress, let services else { return }
        var text = "ImageGen · " + phase
        if let remaining, remaining > 5 { text += " · " + Self.duration(remaining) + " left" }
        if queuedCount > 0 { text += " · \(queuedCount) more queued" }
        // Re-draw the pill only when what it says changes, or the ring moves a whole percent.
        let key = (text, Int((fraction ?? -1) * 100))
        if let lastHUD, lastHUD == key { return }
        lastHUD = key
        services.showHUDProgress(OnecastHUDProgress(message: text, fraction: fraction)) { [weak self] in
            self?.cancel(id)
        }
    }

    private func run(_ id: UUID) async {
        guard let job = jobs.first(where: { $0.id == id }), job.state == .queued else { return }
        update(id) { $0.state = .running }
        save()
        let started = Date()
        let request = job.request
        let client = ComfyClient(base: Settings.serverURL)
        do {
            if !catalogLoaded {
                catalog = await Task.detached { [models = Settings.modelsFolder, looks = Settings.looksRoot] in
                    Catalog.scan(modelsRoot: models, looksRoot: looks)
                }.value
                catalogLoaded = true
            }
            while MemoryGuard.videoRenderRunning() {
                try checkCancelled(id)
                report(id, "Waiting for a video render to finish")
                try await Task.sleep(nanoseconds: 10_000_000_000)
            }
            if await !client.isRunning() {
                report(id, "Starting ComfyUI")
                try await client.start(command: Settings.startCommand)
            }
            try checkCancelled(id)
            var referenceNames: [String] = []
            for path in request.references {
                report(id, "Uploading references")
                referenceNames.append(try await client.upload(URL(fileURLWithPath: path)))
            }
            let folder = Settings.outputFolder
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let stem = Self.fileStem(request.prompt, date: started)
            let (w, h) = request.aspect.size(for: request.family, draft: request.draft)
            let timingKey = "\(request.modelID)|\(request.quality.rawValue)|\(w)x\(h)"

            for index in 0..<request.count {
                try checkCancelled(id)
                let seed = request.seed.map { $0 + index } ?? Int.random(in: 0..<Int(Int32.max))
                let graph = Workflow.graph(request, seed: seed, catalog: catalog, referenceNames: referenceNames,
                                           prefix: "imagegen")
                let imageStart = Date()
                let data = try await render(id, graph: graph, client: client, index: index, count: request.count,
                                            title: request.modelTitle, timingKey: timingKey)
                timings[timingKey] = Date().timeIntervalSince(imageStart)
                let name = request.count > 1 ? "\(stem)-\(index + 1).png" : "\(stem).png"
                let url = Self.unique(folder.appendingPathComponent(name))
                try data.write(to: url)
                if Settings.saveSettings {
                    var sidecar = request
                    sidecar.seed = seed
                    if let json = try? JSONEncoder.pretty.encode(sidecar) {
                        try? json.write(to: url.deletingPathExtension().appendingPathExtension("json"))
                    }
                }
                update(id) {
                    $0.outputs.append(url.path)
                    $0.seeds.append(seed)
                }
                save()
            }
            update(id) {
                $0.state = .done
                $0.finished = Date()
                $0.seconds = Date().timeIntervalSince(started)
            }
            finish(id, failure: nil)
        } catch {
            let wasCancelled = cancelled.contains(id) || error is CancellationError
            update(id) {
                $0.state = wasCancelled ? .cancelled : .failed
                $0.error = wasCancelled ? nil : error.localizedDescription
                $0.finished = Date()
                $0.seconds = Date().timeIntervalSince(started)
            }
            finish(id, failure: wasCancelled ? nil : error.localizedDescription)
        }
        cancelled.remove(id)
        activePrompt = nil
        live[id] = nil
        save()
    }

    private func checkCancelled(_ id: UUID) throws {
        if cancelled.contains(id) { throw CancellationError() }
    }

    /// Queues one graph and follows it to its image: live steps from the socket, the result (or the
    /// error) from the history, which also covers a socket that dropped.
    private func render(
        _ id: UUID, graph: [String: Any], client: ComfyClient, index: Int, count: Int, title: String, timingKey: String
    ) async throws -> Data {
        let events = client.events()
        let tracker = StepTracker()
        let listener = Task { @MainActor [weak self] in
            for await event in events {
                guard let self, let type = event["type"] as? String, let data = event["data"] as? [String: Any] else { continue }
                if type == "progress", let value = (data["value"] as? NSNumber)?.intValue,
                    let max = (data["max"] as? NSNumber)?.intValue, max > 0 {
                    if tracker.since == nil { tracker.since = Date() }
                    tracker.step = (value, max)
                    let fraction = (Double(index) + Double(value) / Double(max)) / Double(count)
                    var remaining: TimeInterval?
                    if let since = tracker.since, value > 0 {
                        let perStep = Date().timeIntervalSince(since) / Double(value)
                        let thisImage = perStep * Double(max - value)
                        let later = Double(count - index - 1) * (self.timings[timingKey] ?? perStep * Double(max) * 1.3)
                        remaining = thisImage + later
                    }
                    let label = count > 1 ? "Image \(index + 1) of \(count) · \(Int(fraction * 100))%" : "\(Int(fraction * 100))%"
                    self.report(id, label, fraction: fraction, remaining: remaining)
                }
            }
        }
        defer { listener.cancel() }
        try await Task.sleep(nanoseconds: 200_000_000)  // let the socket connect before the prompt runs
        let prompt = try await client.queue(graph)
        activePrompt = (id, prompt, client)
        let base = Double(index) / Double(count)
        while true {
            try checkCancelled(id)
            if let data = try await client.output(of: prompt) {
                return data
            }
            if tracker.step.1 == 0 {
                if let ahead = await client.ahead(of: prompt), ahead > 0 {
                    report(id, "Waiting in ComfyUI's queue (\(ahead) ahead)", fraction: count > 1 ? base : nil)
                } else {
                    report(id, "Loading \(title)", fraction: count > 1 ? base : nil)
                }
            } else if tracker.step.0 >= tracker.step.1 {
                report(id, "Saving", fraction: (Double(index) + 1) / Double(count))
            }
            try await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    private func finish(_ id: UUID, failure: String?) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        lastHUD = nil
        guard let services else { return }
        if failure == nil, job.state == .cancelled {
            services.showHUD("ImageGen: cancelled", tone: .info)
            return
        }
        if let failure {
            services.showHUD("ImageGen failed: \(failure)", tone: .failure)
            if Settings.showCard {
                services.notify(OnecastNotification(
                    title: "ImageGen couldn't make the image", body: failure, tint: .red, dwell: nil))
            }
            return
        }
        let urls = job.outputURLs
        let took = job.seconds.map { " in " + Self.duration($0) } ?? ""
        let what = urls.count == 1 ? "Image ready" : "\(urls.count) images ready"
        services.showHUD("\(what)\(took) · \(urls.first?.lastPathComponent ?? "")", tone: .success)
        guard Settings.showCard, let first = urls.first else { return }
        services.notify(
            OnecastNotification(
                title: what,
                body: "\(job.request.modelTitle) · \(job.request.aspect.rawValue)\(took)\n\((first.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)",
                tint: .purple,
                actions: [OnecastNotificationAction(id: "open", title: "Open"),
                          OnecastNotificationAction(id: "reveal", title: "Show in Finder")],
                dwell: 15)
        ) { action in
            switch action {
            case "open": urls.forEach { NSWorkspace.shared.open($0) }
            case "reveal": NSWorkspace.shared.activateFileViewerSelecting(urls)
            default: break
            }
        }
    }

    // MARK: History on disk

    private static var historyURL: URL {
        let bundle = Bundle.main.bundleIdentifier ?? "com.onecast.app"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundle).appendingPathComponent("plugin-data")
            .appendingPathComponent(Settings.pluginID).appendingPathComponent("history.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.historyURL) else { return }
        guard var saved = try? JSONDecoder.iso.decode([Job].self, from: data) else {
            // Unreadable (an older or newer format): keep it aside instead of overwriting it.
            let aside = Self.historyURL.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: Self.historyURL, to: aside)
            return
        }
        // Work that was in flight when OneCast quit didn't finish; say so rather than show it running.
        for index in saved.indices where saved[index].isActive {
            saved[index].state = .failed
            saved[index].error = "Stopped when OneCast quit"
        }
        jobs = saved
    }

    private func save() {
        let keep = Array(jobs.prefix(200))
        guard let data = try? JSONEncoder.pretty.encode(keep) else { return }
        try? FileManager.default.createDirectory(at: Self.historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.historyURL, options: .atomic)
    }

    // MARK: Naming

    static func fileStem(_ prompt: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let words = prompt.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !["the", "and", "with", "she", "her", "his", "for", "very"].contains($0) }
            .prefix(5)
        return formatter.string(from: date) + (words.isEmpty ? "" : "_" + words.joined(separator: "-"))
    }

    static func unique(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) (\(n)).\(url.pathExtension)")
            n += 1
        }
        return candidate
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        let m = s / 60, r = s % 60
        return r >= 30 && m < 10 ? "\(m) min \(r) s" : "\(Int((seconds / 60).rounded())) min"
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}
