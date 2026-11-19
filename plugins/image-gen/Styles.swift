import Foundation

/// Prompt-only styles that work on every model, the user's own from `styles.json`, and the
/// LoRA looks ImageGen leaves out.
enum Styles {
    /// LoRA looks from Jarvis that ImageGen doesn't offer.
    static func hidden(_ name: String) -> Bool { name.lowercased().contains("clay") }

    private static func look(_ title: String, _ before: String, _ after: String, avoid: String = "") -> StylePreset {
        StylePreset(id: "look:" + title.lowercased().replacingOccurrences(of: " ", with: "-"), title: title,
                    family: nil, loras: [], trigger: before, suffix: after, negative: avoid, group: .look)
    }

    static let builtIn: [StylePreset] = [
        look("Cinematic", "cinematic film still,", "anamorphic lens, dramatic lighting, shallow depth of field, film grain, color graded", avoid: "flat lighting, cartoon"),
        look("Photoreal", "ultra realistic photograph,", "natural light, sharp focus, high detail, 50mm lens, true-to-life skin and textures", avoid: "painting, illustration, cartoon, 3d render"),
        look("Studio Portrait", "studio portrait photograph,", "softbox lighting, seamless backdrop, 85mm lens, crisp detail on the eyes", avoid: "cluttered background"),
        look("Golden Hour", "", "golden hour sunlight, warm glow, long soft shadows, gentle haze, backlit"),
        look("Moody Night", "", "night scene, moody low-key lighting, deep shadows, glowing practical lights, atmospheric"),
        look("Film Noir", "black and white film noir still,", "hard light, venetian-blind shadows, high contrast, smoky atmosphere", avoid: "color"),
        look("Vintage Film", "35mm analog film photo,", "Kodak Portra colors, soft grain, slight light leak, nostalgic", avoid: "digital, oversharpened"),
        look("Polaroid", "instant polaroid photo,", "faded colors, soft focus, white frame border, flash snapshot"),
        look("Aerial", "aerial drone photograph,", "top-down perspective, vast scale, crisp detail"),
        look("Macro", "macro photograph,", "extreme close-up, tiny details, creamy bokeh background"),
        look("Product Shot", "professional product photograph,", "clean studio background, soft reflections, commercial lighting", avoid: "clutter, text"),
        look("Anime", "anime illustration,", "clean line art, cel shading, vibrant colors, detailed background", avoid: "photo, realistic"),
        look("Hand-drawn Animation", "hand-drawn animated film frame,", "soft painted backgrounds, warm palette, gentle whimsical mood", avoid: "photo, 3d"),
        look("3D Animated", "3D animated film still,", "stylized characters, soft global illumination, subsurface scattering, rich color", avoid: "photo"),
        look("Comic Book", "comic book art,", "bold ink outlines, halftone shading, dynamic composition, saturated colors", avoid: "photo"),
        look("Watercolor", "watercolor painting,", "soft washes, bleeding edges, textured paper, delicate pigment", avoid: "photo, 3d"),
        look("Oil Painting", "oil painting on canvas,", "visible brushstrokes, rich impasto, classical lighting", avoid: "photo"),
        look("Ink Wash", "traditional ink wash painting,", "sumi-e brushwork, flowing ink, rice paper, minimal and serene", avoid: "photo, color"),
        look("Pencil Sketch", "detailed graphite pencil sketch,", "cross-hatching, paper texture, monochrome", avoid: "color, photo"),
        look("Charcoal", "expressive charcoal drawing,", "smudged tones, strong contrast, textured paper", avoid: "color, photo"),
        look("Woodblock Print", "Japanese woodblock print,", "flat color areas, bold outlines, washi paper texture", avoid: "photo, 3d"),
        look("Art Nouveau", "art nouveau illustration,", "ornate flowing lines, decorative floral border, muted gold palette"),
        look("Stained Glass", "stained glass window,", "lead outlines, glowing jewel-tone glass, light shining through"),
        look("Paper Cut", "layered paper cut art,", "depth shadows between layers, crisp edges, handcrafted"),
        look("Low Poly", "low poly 3D art,", "faceted geometry, flat shading, clean pastel colors"),
        look("Isometric", "isometric 3D diorama,", "tiny detailed world, soft lighting, tilt-shift"),
        look("Pixel Art", "pixel art,", "16-bit, limited palette, crisp pixels", avoid: "blurry, smooth gradients"),
        look("Cyberpunk", "", "cyberpunk, neon signs, rain-slick streets, magenta and cyan glow, futuristic city"),
        look("Fantasy Art", "epic fantasy painting,", "magical light, intricate detail, sweeping vista"),
        look("Dark Fantasy", "dark fantasy art,", "gothic atmosphere, ominous light, muted palette, intricate detail"),
        look("Surreal", "surreal dreamlike art,", "impossible scale, floating objects, soft otherworldly light"),
        look("Double Exposure", "double exposure photograph,", "silhouette blended with landscape, ethereal overlay"),
        look("Minimalist", "minimalist composition,", "lots of negative space, simple shapes, calm muted palette", avoid: "clutter"),
        look("Vaporwave", "vaporwave aesthetic,", "pastel pink and teal, retro 80s grid, glitch, sunset gradient"),
        look("Line Art", "clean line art illustration,", "single weight black lines on white, no shading", avoid: "color, shading, photo"),
        look("Spiritual Glow", "", "divine soft light, sacred serene atmosphere, gentle rays, ethereal glow"),
    ]

    /// `styles.json` in ImageGen's data folder: `[{"name", "before", "after", "avoid"}]`.
    static var customFile: URL {
        let bundle = Bundle.main.bundleIdentifier ?? "com.onecast.app"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundle).appendingPathComponent("plugin-data")
            .appendingPathComponent("com.sujha.imagegen").appendingPathComponent("styles.json")
    }

    static func custom() -> [StylePreset] {
        guard let data = try? Data(contentsOf: customFile),
            let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return list.compactMap { item in
            guard let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
            return StylePreset(id: "custom:" + name, title: name, family: nil, loras: [],
                               trigger: item["before"] as? String ?? "", suffix: item["after"] as? String ?? "",
                               negative: item["avoid"] as? String ?? "", group: .custom)
        }
    }

    /// Creates `styles.json` with one example when it doesn't exist, and returns its location.
    static func ensureCustomFile() -> URL {
        let url = customFile
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let sample = """
            [
              {
                "name": "My Style",
                "before": "text added before your prompt,",
                "after": "text added after your prompt, lighting, mood, detail",
                "avoid": "things to keep out"
              }
            ]

            """
            try? sample.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }
}
