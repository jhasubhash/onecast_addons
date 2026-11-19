import Foundation

/// What one render asks for, kept with the job so it can be shown, retried or reused later.
struct GenerationRequest: Codable, Hashable, Sendable {
    var prompt: String
    var negative: String
    var modelID: String
    var modelTitle: String
    var family: ModelFamily
    var loader: ModelLoader
    var aspect: AspectRatio
    var quality: Quality
    var draft: Bool
    var styleID: String?
    var loras: [LoraUse]
    var trigger: String
    var suffix: String
    var seed: Int?
    var count: Int
    var references: [String]
    var safe: Bool
}

enum ComfyError: LocalizedError {
    case notRunning(String)
    case server(String)
    case noImage

    var errorDescription: String? {
        switch self {
        case .notRunning(let why): why
        case .server(let message): message
        case .noImage: "ComfyUI finished without an image."
        }
    }
}

/// Negative prompts: quality fixes always, the safety terms while Safe mode is on (the default).
enum Negative {
    static let quality = "text, watermark, signature, logo, deformed hands, extra fingers, extra limbs, "
        + "blurry, lowres, jpeg artifacts"
    static let unsafe = "nude, naked, nsfw, nipples, genitals, explicit, sexual act"

    static func text(user: String, safe: Bool) -> String {
        [safe ? unsafe : "", quality, user.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

// MARK: - Workflows

/// ComfyUI API graphs for each family, ported from Jarvis's engine/comfy.py where it has one.
enum Workflow {
    static func graph(
        _ r: GenerationRequest, seed: Int, catalog: Catalog, referenceNames: [String], prefix: String
    ) -> [String: Any] {
        let (w, h) = r.aspect.size(for: r.family, draft: r.draft)
        let plan = SamplerPlan.plan(r.family, r.quality, catalog: catalog)
        let positive = [r.trigger.trimmingCharacters(in: .whitespaces), r.prompt.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }.joined(separator: ", ")
            + (r.suffix.trimmingCharacters(in: .whitespaces).isEmpty ? "" : " " + r.suffix.trimmingCharacters(in: .whitespaces))
        let negative = Negative.text(user: r.negative, safe: r.safe)
        switch r.family {
        case .qwenImage, .qwenImage2512:
            return qwen(r, w: w, h: h, plan: plan, positive: positive, negative: negative, seed: seed, catalog: catalog, prefix: prefix)
        case .qwenEdit:
            return qwenEdit(r, w: w, h: h, plan: plan, positive: positive, negative: negative, seed: seed,
                            catalog: catalog, references: referenceNames, prefix: prefix)
        case .sdxl, .sdxlTurbo, .sd15:
            return checkpoint(r, w: w, h: h, plan: plan, positive: positive, negative: negative, seed: seed, prefix: prefix)
        }
    }

    private static func unet(_ r: GenerationRequest) -> [String: Any] {
        r.loader == .gguf
            ? ["class_type": "UnetLoaderGGUF", "inputs": ["unet_name": r.modelID]]
            : ["class_type": "UNETLoader", "inputs": ["unet_name": r.modelID, "weight_dtype": "default"]]
    }

    private static func sampler(_ plan: SamplerPlan, model: String, seed: Int, latent: String = "8") -> [String: Any] {
        ["class_type": "KSampler", "inputs": [
            "model": [model, 0], "positive": ["6", 0], "negative": ["7", 0], "latent_image": [latent, 0],
            "seed": seed, "steps": plan.steps, "cfg": plan.cfg, "sampler_name": plan.sampler,
            "scheduler": plan.scheduler, "denoise": 1.0,
        ] as [String: Any]]
    }

    private static func qwen(
        _ r: GenerationRequest, w: Int, h: Int, plan: SamplerPlan, positive: String, negative: String,
        seed: Int, catalog: Catalog, prefix: String
    ) -> [String: Any] {
        let chain = (plan.speedLora.map { [LoraUse(file: $0, strength: 1)] } ?? []) + r.loras
        var g: [String: Any] = [
            "1": unet(r),
            "2": ["class_type": "CLIPLoader", "inputs": ["clip_name": catalog.textEncoder ?? "", "type": "qwen_image"]],
            "3": ["class_type": "VAELoader", "inputs": ["vae_name": catalog.vae ?? ""]],
            "5": ["class_type": "ModelSamplingAuraFlow", "inputs": [
                "model": [chain.isEmpty ? "1" : "4\(chain.count - 1)", 0], "shift": 3.1] as [String: Any]],
            "6": ["class_type": "CLIPTextEncode", "inputs": ["clip": ["2", 0], "text": positive] as [String: Any]],
            "7": ["class_type": "CLIPTextEncode", "inputs": ["clip": ["2", 0], "text": negative] as [String: Any]],
            "8": ["class_type": "EmptySD3LatentImage", "inputs": ["width": w, "height": h, "batch_size": 1]],
            "9": sampler(plan, model: "5", seed: seed),
            "10": ["class_type": "VAEDecode", "inputs": ["samples": ["9", 0], "vae": ["3", 0]]],
            "11": ["class_type": "SaveImage", "inputs": ["images": ["10", 0], "filename_prefix": prefix] as [String: Any]],
        ]
        for (n, lora) in chain.enumerated() {
            g["4\(n)"] = ["class_type": "LoraLoaderModelOnly", "inputs": [
                "model": [n == 0 ? "1" : "4\(n - 1)", 0], "lora_name": lora.file, "strength_model": lora.strength,
            ] as [String: Any]]
        }
        return g
    }

    private static func qwenEdit(
        _ r: GenerationRequest, w: Int, h: Int, plan: SamplerPlan, positive: String, negative: String,
        seed: Int, catalog: Catalog, references: [String], prefix: String
    ) -> [String: Any] {
        let model = plan.speedLora == nil ? "1" : "4"
        var g: [String: Any] = [
            "1": unet(r),
            "2": ["class_type": "CLIPLoader", "inputs": ["clip_name": catalog.textEncoder ?? "", "type": "qwen_image"]],
            "3": ["class_type": "VAELoader", "inputs": ["vae_name": catalog.vae ?? ""]],
            "5": ["class_type": "ModelSamplingAuraFlow", "inputs": ["model": [model, 0], "shift": 3.0] as [String: Any]],
            "8": ["class_type": "EmptySD3LatentImage", "inputs": ["width": w, "height": h, "batch_size": 1]],
            "9": sampler(plan, model: "5", seed: seed),
            "10": ["class_type": "VAEDecode", "inputs": ["samples": ["9", 0], "vae": ["3", 0]]],
            "11": ["class_type": "SaveImage", "inputs": ["images": ["10", 0], "filename_prefix": prefix] as [String: Any]],
        ]
        if let lora = plan.speedLora {
            g["4"] = ["class_type": "LoraLoaderModelOnly", "inputs": [
                "model": ["1", 0], "lora_name": lora, "strength_model": 1.0] as [String: Any]]
        }
        var pos: [String: Any] = ["clip": ["2", 0], "prompt": positive, "vae": ["3", 0]]
        var neg: [String: Any] = ["clip": ["2", 0], "prompt": negative, "vae": ["3", 0]]
        for (n, name) in references.prefix(3).enumerated() {
            g["2\(n + 1)"] = ["class_type": "LoadImage", "inputs": ["image": name]]
            pos["image\(n + 1)"] = ["2\(n + 1)", 0]
            neg["image\(n + 1)"] = ["2\(n + 1)", 0]
        }
        g["6"] = ["class_type": "TextEncodeQwenImageEditPlus", "inputs": pos]
        g["7"] = ["class_type": "TextEncodeQwenImageEditPlus", "inputs": neg]
        return g
    }

    private static func checkpoint(
        _ r: GenerationRequest, w: Int, h: Int, plan: SamplerPlan, positive: String, negative: String,
        seed: Int, prefix: String
    ) -> [String: Any] {
        [
            "1": ["class_type": "CheckpointLoaderSimple", "inputs": ["ckpt_name": r.modelID]],
            "6": ["class_type": "CLIPTextEncode", "inputs": ["clip": ["1", 1], "text": positive] as [String: Any]],
            "7": ["class_type": "CLIPTextEncode", "inputs": ["clip": ["1", 1], "text": negative] as [String: Any]],
            "8": ["class_type": "EmptyLatentImage", "inputs": ["width": w, "height": h, "batch_size": 1]],
            "9": sampler(plan, model: "1", seed: seed),
            "10": ["class_type": "VAEDecode", "inputs": ["samples": ["9", 0], "vae": ["1", 2]]],
            "11": ["class_type": "SaveImage", "inputs": ["images": ["10", 0], "filename_prefix": prefix] as [String: Any]],
        ]
    }
}

// MARK: - Client

/// Progress ComfyUI reports while a prompt runs.
enum ComfyEvent: Sendable {
    case queued(ahead: Int)
    case started
    case step(Int, Int)
    case node(String)
    case finished
    case failed(String)
}

/// A thin client for one ComfyUI server. Requests go over a private ephemeral session.
final class ComfyClient: @unchecked Sendable {
    let base: URL
    let clientID = UUID().uuidString
    private let session: URLSession

    init(base: URL) {
        self.base = base
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    func isRunning() async -> Bool {
        var request = URLRequest(url: base.appendingPathComponent("system_stats"))
        request.timeoutInterval = 3
        return (try? await session.data(for: request)).map { ($0.1 as? HTTPURLResponse)?.statusCode == 200 } ?? false
    }

    /// Starts the server with the user's command and waits up to `wait` seconds for it to answer.
    func start(command: String, wait: TimeInterval = 240) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            throw ComfyError.notRunning("Couldn't run the start command: \(error.localizedDescription)")
        }
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            if await isRunning() { return }
        }
        throw ComfyError.notRunning("ComfyUI didn't start within \(Int(wait)) s. Check the start command in Settings › Plugins › ImageGen.")
    }

    private func json(_ path: String, body: Any? = nil) async throws -> Any {
        var request = URLRequest(url: base.appendingPathComponent(path))
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 400 {
            throw ComfyError.server(Self.describe(errorBody: data) ?? "ComfyUI answered \(status).")
        }
        return data.isEmpty ? [:] : try JSONSerialization.jsonObject(with: data)
    }

    /// ComfyUI's validation errors name the node and input; keep the first readable one.
    private static func describe(errorBody data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let nodes = obj["node_errors"] as? [String: Any], let first = nodes.values.first as? [String: Any],
            let errs = first["errors"] as? [[String: Any]], let e = errs.first {
            return [e["message"] as? String, e["details"] as? String].compactMap { $0 }.joined(separator: ": ")
        }
        if let err = obj["error"] as? [String: Any] { return err["message"] as? String }
        return nil
    }

    func queue(_ graph: [String: Any]) async throws -> String {
        let reply = try await json("prompt", body: ["prompt": graph, "client_id": clientID]) as? [String: Any]
        guard let id = reply?["prompt_id"] as? String else { throw ComfyError.server("ComfyUI didn't accept the prompt.") }
        return id
    }

    /// How many prompts are ahead of `promptID`; nil once it is running or done.
    func ahead(of promptID: String) async -> Int? {
        guard let q = try? await json("queue") as? [String: Any] else { return nil }
        let running = (q["queue_running"] as? [[Any]]) ?? []
        if running.contains(where: { ($0.dropFirst().first as? String) == promptID }) { return nil }
        let pending = ((q["queue_pending"] as? [[Any]]) ?? []).sorted {
            (($0.first as? NSNumber)?.intValue ?? 0) < (($1.first as? NSNumber)?.intValue ?? 0)
        }
        guard let index = pending.firstIndex(where: { ($0.dropFirst().first as? String) == promptID }) else { return nil }
        return index + running.count
    }

    /// The saved image of a finished prompt, or nil while it is still running.
    func output(of promptID: String) async throws -> Data? {
        guard let history = try await json("history/\(promptID)") as? [String: Any],
            let entry = history[promptID] as? [String: Any]
        else { return nil }
        if let status = entry["status"] as? [String: Any], status["status_str"] as? String == "error" {
            let messages = (status["messages"] as? [[Any]]) ?? []
            let error = messages.first { ($0.first as? String) == "execution_error" }?.dropFirst().first as? [String: Any]
            throw ComfyError.server((error?["exception_message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "ComfyUI reported an error.")
        }
        let outputs = (entry["outputs"] as? [String: Any]) ?? [:]
        for case let node as [String: Any] in outputs.values {
            guard let image = (node["images"] as? [[String: Any]])?.first,
                let filename = image["filename"] as? String
            else { continue }
            var parts = URLComponents(url: base.appendingPathComponent("view"), resolvingAgainstBaseURL: false)!
            parts.queryItems = [
                URLQueryItem(name: "filename", value: filename),
                URLQueryItem(name: "subfolder", value: image["subfolder"] as? String ?? ""),
                URLQueryItem(name: "type", value: image["type"] as? String ?? "output"),
            ]
            let (data, _) = try await session.data(from: parts.url!)
            return data
        }
        if entry["status"] != nil { throw ComfyError.noImage }
        return nil
    }

    func upload(_ file: URL) async throws -> String {
        let boundary = "imagegen-\(UUID().uuidString)"
        var body = Data()
        let name = "imagegen_\(UUID().uuidString.prefix(8))_\(file.lastPathComponent)"
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(name)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: file))
        body.append("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\ntrue\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var request = URLRequest(url: base.appendingPathComponent("upload/image"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, _) = try await session.data(for: request)
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any], let stored = reply["name"] as? String else {
            throw ComfyError.server("ComfyUI didn't take the reference image \(file.lastPathComponent).")
        }
        return stored
    }

    /// Stops `promptID`: removed from the queue if it is waiting, interrupted if it is running.
    func cancel(_ promptID: String) async {
        _ = try? await json("queue", body: ["delete": [promptID]])
        if await ahead(of: promptID) == nil { _ = try? await json("interrupt", body: ["prompt_id": promptID]) }
    }

    /// ComfyUI's live events for this client. Ends when the socket closes.
    func events() -> AsyncStream<[String: Any]> {
        var parts = URLComponents(url: base.appendingPathComponent("ws"), resolvingAgainstBaseURL: false)!
        parts.scheme = base.scheme == "https" ? "wss" : "ws"
        parts.queryItems = [URLQueryItem(name: "clientId", value: clientID)]
        let task = session.webSocketTask(with: parts.url!)
        task.resume()
        return AsyncStream { continuation in
            let reader = Task {
                while !Task.isCancelled {
                    guard let message = try? await task.receive() else { break }
                    if case .string(let text) = message, let data = text.data(using: .utf8),
                        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        continuation.yield(obj)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                reader.cancel()
                task.cancel(with: .goingAway, reason: nil)
            }
        }
    }
}

// MARK: - Sharing the Mac

/// Jarvis renders local video with LTX outside ComfyUI, and running both at once once ran the Mac
/// out of memory. While its render's pid (in ~/Jarvis/run/local-video.json) is alive, wait.
enum MemoryGuard {
    static func videoRenderRunning() -> Bool {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Jarvis/run/local-video.json")
        guard let data = try? Data(contentsOf: file),
            let jobs = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        for case let job as [String: Any] in jobs.values {
            if let pid = (job["pid"] as? NSNumber)?.int32Value, kill(pid, 0) == 0 { return true }
        }
        return false
    }
}
