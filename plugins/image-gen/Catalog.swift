import Foundation

// MARK: - Models

/// The families ImageGen knows how to wire into a ComfyUI graph. Each one differs in its loaders,
/// its native resolution and its sampler settings; a file is sorted into one by its name.
enum ModelFamily: String, Codable, Sendable {
    case qwenImage, qwenImage2512, qwenEdit, sdxl, sdxlTurbo, sd15

    /// Pixel budget the model was trained around: it looks best near this many pixels.
    var nativeSide: Int {
        switch self {
        case .qwenImage, .qwenImage2512, .qwenEdit: 1328
        case .sdxl: 1024
        case .sdxlTurbo, .sd15: 512
        }
    }

    var isQwen: Bool { self == .qwenImage || self == .qwenImage2512 || self == .qwenEdit }
}

/// How a family loads its weights.
enum ModelLoader: String, Codable, Sendable {
    case gguf        // UnetLoaderGGUF + separate text encoder and VAE
    case diffusion   // UNETLoader + separate text encoder and VAE
    case checkpoint  // CheckpointLoaderSimple: weights, CLIP and VAE in one file
}

struct ImageModel: Identifiable, Hashable, Sendable {
    /// The file name, unique across ComfyUI's model folders.
    let id: String
    let title: String
    let family: ModelFamily
    let loader: ModelLoader
    let sizeBytes: Int64
    /// Why it can't run, when a companion file (text encoder, VAE) is missing.
    var missing: String?

    var needsReference: Bool { family == .qwenEdit }
    var usable: Bool { missing == nil }

    var detail: String {
        let gb = Double(sizeBytes) / 1_073_741_824
        let size = gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", gb * 1024)
        if let missing { return "Needs \(missing)" }
        switch family {
        case .qwenImage: return "Qwen-Image · best text and detail · \(size)"
        case .qwenImage2512: return "Newest Qwen · most realistic · \(size)"
        case .qwenEdit: return "Edits or restyles 1–3 reference images · \(size)"
        case .sdxl: return "Stable Diffusion XL · \(size)"
        case .sdxlTurbo: return "One-to-four-step drafts in seconds · \(size)"
        case .sd15: return "Stable Diffusion 1.5 · \(size)"
        }
    }
}

/// A LoRA file with the base it was trained on, so only fitting ones are offered.
struct LoraFile: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    /// Families it is known to work with; empty means unknown, offered to every Qwen model.
    let families: Set<ModelFamily>
}

/// A named look: base model, LoRAs and the trigger words the LoRAs were trained with. Read from
/// Jarvis's `looks.json` files when they exist, so the styles tested there are one click away here.
struct StylePreset: Identifiable, Hashable, Sendable {
    enum Group: Int, Sendable { case custom, look, lora }
    let id: String
    let title: String
    /// The model family its LoRAs need; nil for a prompt-only style, which works on every model.
    let family: ModelFamily?
    let loras: [LoraUse]
    let trigger: String
    let suffix: String
    var negative = ""
    var group: Group = .lora
}

struct LoraUse: Hashable, Codable, Sendable {
    let file: String
    let strength: Double
}

/// What ComfyUI's model folders hold, read from disk so it works before the server is up.
struct Catalog: Sendable {
    var models: [ImageModel] = []
    var loras: [LoraFile] = []
    var styles: [StylePreset] = []
    var textEncoder: String?
    var vae: String?
    var lightning: String?
    var editLightning: String?

    func model(_ id: String?) -> ImageModel? { models.first { $0.id == id } }

    func loras(for family: ModelFamily) -> [LoraFile] {
        guard family.isQwen, family != .qwenEdit else { return [] }
        return loras.filter { $0.families.isEmpty || $0.families.contains(family) }
    }

    func styles(for family: ModelFamily) -> [StylePreset] {
        styles.filter { $0.family == nil || $0.family == family }
    }

    /// The best model to start on: the newest Qwen when it is there.
    var preferred: ImageModel? {
        let order: [ModelFamily] = [.qwenImage2512, .qwenImage, .sdxl, .sdxlTurbo, .sd15, .qwenEdit]
        for family in order {
            if let m = models.first(where: { $0.family == family && $0.usable }) { return m }
        }
        return models.first
    }

    // MARK: Scanning

    nonisolated static func scan(modelsRoot: URL, looksRoot: URL?) -> Catalog {
        var c = Catalog()
        let fm = FileManager.default
        func files(_ folder: String) -> [(name: String, size: Int64)] {
            let dir = modelsRoot.appendingPathComponent(folder)
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
            return names.filter { $0.hasSuffix(".safetensors") || $0.hasSuffix(".gguf") || $0.hasSuffix(".ckpt") }
                .sorted()
                .map { name in
                    let attributes = try? fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path)
                    return (name, (attributes?[.size] as? NSNumber)?.int64Value ?? 0)
                }
        }

        c.textEncoder = files("text_encoders").first { $0.name.lowercased().contains("qwen_2.5_vl") }?.name
        c.vae = files("vae").first { $0.name.lowercased().contains("qwen_image") }?.name
        let loraFiles = files("loras")
        c.lightning = loraFiles.first { $0.name.hasPrefix("Qwen-Image-Lightning") }?.name
        c.editLightning = loraFiles.first { $0.name.hasPrefix("Qwen-Image-Edit") && $0.name.contains("Lightning") }?.name

        let qwenMissing: String? = {
            var parts: [String] = []
            if c.textEncoder == nil { parts.append("the Qwen 2.5 VL text encoder") }
            if c.vae == nil { parts.append("the Qwen-Image VAE") }
            return parts.isEmpty ? nil : parts.joined(separator: " and ")
        }()

        var seenQwenBase = false
        for (folder, loader) in [("unet", ModelLoader.gguf), ("diffusion_models", .diffusion)] {
            for file in files(folder) {
                let n = file.name.lowercased()
                if n.contains("wan") || n.contains("hunyuan") || n.contains("ltx") { continue }  // video models
                let actual: ModelLoader = n.hasSuffix(".gguf") ? .gguf : loader
                if n.contains("qwen") && n.contains("edit") {
                    c.models.append(ImageModel(id: file.name, title: "Qwen-Image-Edit" + (n.contains("2509") ? " 2509" : ""),
                                               family: .qwenEdit, loader: actual, sizeBytes: file.size, missing: qwenMissing))
                } else if n.contains("qwen") && n.contains("2512") {
                    c.models.append(ImageModel(id: file.name, title: "Qwen-Image 2512", family: .qwenImage2512,
                                               loader: actual, sizeBytes: file.size, missing: qwenMissing))
                } else if n.contains("qwen") && n.contains("image") {
                    // The fp8 file expands to 39 GB on Apple silicon; its GGUF twin stays near 22 GB and
                    // looks the same, so only one Qwen-Image is offered, preferring the GGUF.
                    if seenQwenBase { continue }
                    seenQwenBase = true
                    c.models.append(ImageModel(id: file.name, title: "Qwen-Image", family: .qwenImage,
                                               loader: actual, sizeBytes: file.size, missing: qwenMissing))
                }
            }
        }
        for file in files("checkpoints") {
            let n = file.name.lowercased()
            let family: ModelFamily = n.contains("turbo") || n.contains("lightning") ? .sdxlTurbo
                : (n.contains("xl") ? .sdxl : .sd15)
            let base = (file.name as NSString).deletingPathExtension
            let title = family == .sdxlTurbo && n.contains("sd_xl_turbo") ? "SDXL Turbo" : prettify(base)
            c.models.append(ImageModel(id: file.name, title: title, family: family, loader: .checkpoint, sizeBytes: file.size))
        }

        for file in loraFiles {
            let n = file.name.lowercased()
            if n.contains("lightning") || n.contains("lightx2v") || n.contains("wan") || n.contains("edit") { continue }
            let families: Set<ModelFamily> = n.hasPrefix("qi2512") ? [.qwenImage2512]
                : (n.contains("qwen") || n.hasPrefix("cv-") ? [.qwenImage] : [])
            let title = prettify((file.name as NSString).deletingPathExtension
                .replacingOccurrences(of: "qi2512-", with: "").replacingOccurrences(of: "cv-", with: ""))
            c.loras.append(LoraFile(id: file.name, title: title, families: families))
        }

        let loraStyles = looksRoot.map { styles(in: $0, loras: Set(loraFiles.map(\.name))) } ?? []
        c.styles = Styles.custom() + Styles.builtIn + loraStyles
        return c
    }

    /// Every look in `<root>/*/looks.json` whose LoRAs are all on disk, deduplicated by name.
    nonisolated private static func styles(in root: URL, loras: Set<String>) -> [StylePreset] {
        let fm = FileManager.default
        guard let accounts = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var byName: [String: StylePreset] = [:]
        for account in accounts.sorted() {
            let url = root.appendingPathComponent(account).appendingPathComponent("looks.json")
            guard let data = try? Data(contentsOf: url),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let looks = (json["looks"] as? [String: Any]) ?? json
            for (name, value) in looks {
                guard !Styles.hidden(name), let look = value as? [String: Any], byName[name] == nil,
                    let pairs = look["loras"] as? [[Any]], !pairs.isEmpty
                else { continue }
                let uses = pairs.compactMap { pair -> LoraUse? in
                    guard let file = pair.first as? String, loras.contains(file) else { return nil }
                    return LoraUse(file: file, strength: (pair.dropFirst().first as? NSNumber)?.doubleValue ?? 1)
                }
                guard uses.count == pairs.count else { continue }
                let family: ModelFamily = (look["base"] as? String) == "qwen-2512" ? .qwenImage2512 : .qwenImage
                byName[name] = StylePreset(
                    id: name, title: prettify(name), family: family, loras: uses,
                    trigger: (look["trigger"] as? String) ?? "", suffix: (look["suffix"] as? String) ?? "")
            }
        }
        return byName.values.sorted { $0.title < $1.title }
    }

    nonisolated static func prettify(_ s: String) -> String {
        s.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

// MARK: - Request options

enum AspectRatio: String, CaseIterable, Codable, Sendable, Identifiable {
    case square = "1:1", portrait45 = "4:5", story = "9:16", portrait23 = "2:3", portrait34 = "3:4"
    case landscape54 = "5:4", wide = "16:9", landscape32 = "3:2", landscape43 = "4:3"

    var id: String { rawValue }

    var ratio: (w: Double, h: Double) {
        let parts = rawValue.split(separator: ":").compactMap { Double($0) }
        return (parts[0], parts[1])
    }

    var label: String {
        switch self {
        case .square: "Square 1:1"
        case .portrait45: "Portrait 4:5"
        case .story: "Story / Reel 9:16"
        case .portrait23: "Portrait 2:3"
        case .portrait34: "Portrait 3:4"
        case .landscape54: "Landscape 5:4"
        case .wide: "Widescreen 16:9"
        case .landscape32: "Landscape 3:2"
        case .landscape43: "Landscape 4:3"
        }
    }

    /// Qwen-Image's own resolution table; 4:5 and 5:4 are at the same pixel count as 3:4.
    private var qwenSize: (Int, Int) {
        switch self {
        case .square: (1328, 1328)
        case .story: (928, 1664)
        case .wide: (1664, 928)
        case .portrait34: (1104, 1472)
        case .landscape43: (1472, 1104)
        case .portrait23: (1056, 1584)
        case .landscape32: (1584, 1056)
        case .portrait45: (1136, 1424)
        case .landscape54: (1424, 1136)
        }
    }

    /// Width and height near the family's pixel budget, both multiples of 16.
    func size(for family: ModelFamily, draft: Bool) -> (Int, Int) {
        func snap(_ v: Double) -> Int { max(256, Int((v / 16).rounded()) * 16) }
        if family.isQwen {
            let (w, h) = qwenSize
            return draft ? (snap(Double(w) * 0.72), snap(Double(h) * 0.72)) : (w, h)
        }
        let side = Double(family.nativeSide) * (draft ? 0.72 : 1)
        let area = side * side
        let (rw, rh) = ratio
        let w = (area * rw / rh).squareRoot()
        let h = area / w
        return (snap(w), snap(h))
    }
}

enum Quality: String, CaseIterable, Codable, Sendable, Identifiable {
    case fast, standard, high
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// Sampler settings for one family at one quality.
struct SamplerPlan: Sendable {
    var steps: Int
    var cfg: Double
    var sampler: String
    var scheduler: String
    /// The speed-up LoRA it relies on (Lightning), if any.
    var speedLora: String?

    static func plan(_ family: ModelFamily, _ quality: Quality, catalog: Catalog) -> SamplerPlan {
        switch family {
        case .qwenImage:
            if quality == .fast, let lightning = catalog.lightning {
                return SamplerPlan(steps: 4, cfg: 1, sampler: "euler", scheduler: "simple", speedLora: lightning)
            }
            return SamplerPlan(steps: quality == .high ? 28 : 20, cfg: 2.5, sampler: "euler", scheduler: "simple")
        case .qwenImage2512:
            return SamplerPlan(steps: quality == .high ? 28 : (quality == .fast ? 14 : 20), cfg: 2.5,
                               sampler: "euler", scheduler: "simple")
        case .qwenEdit:
            if quality != .high, let lightning = catalog.editLightning {
                return SamplerPlan(steps: 8, cfg: 1, sampler: "euler", scheduler: "simple", speedLora: lightning)
            }
            return SamplerPlan(steps: 30, cfg: 4, sampler: "euler", scheduler: "simple")
        case .sdxlTurbo:
            return SamplerPlan(steps: quality == .fast ? 1 : (quality == .high ? 6 : 4), cfg: 1,
                               sampler: "euler_ancestral", scheduler: "normal")
        case .sdxl:
            return SamplerPlan(steps: [Quality.fast: 18, .standard: 28, .high: 40][quality]!, cfg: 6.5,
                               sampler: "dpmpp_2m", scheduler: "karras")
        case .sd15:
            return SamplerPlan(steps: [Quality.fast: 18, .standard: 25, .high: 35][quality]!, cfg: 7,
                               sampler: "dpmpp_2m", scheduler: "karras")
        }
    }

    /// Which qualities mean something different for this family, so the picker never offers a no-op.
    static func qualities(_ family: ModelFamily, catalog: Catalog) -> [Quality] {
        switch family {
        case .qwenImage: catalog.lightning == nil ? [.standard, .high] : Quality.allCases
        case .qwenEdit: catalog.editLightning == nil ? [.high] : [.standard, .high]
        default: Quality.allCases
        }
    }
}
