import AppKit
import ImageIO
import OnecastPluginKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Root

struct RootView: View {
    let center: JobCenter
    let finderImages: [URL]
    let presentation: PluginPresentation

    @State private var nav = PluginNavigator()
    @State private var prompt = ""
    @State private var negative = ""
    @State private var modelID: String?
    @State private var aspect: AspectRatio = .story
    @State private var quality: Quality = .standard
    @State private var draft = false
    @State private var styleID: String?
    @State private var loraID: String?
    @State private var loraStrength = 1.0
    @State private var seedText = ""
    @State private var count = 1
    @State private var references: [URL] = []
    @State private var showAdvanced = false
    @State private var dropTargeted = false
    @State private var notice: String?
    @FocusState private var promptFocused: Bool
    @Environment(\.pluginCloseLauncher) private var closeLauncher

    private var catalog: Catalog { center.catalog }
    private var model: ImageModel? { catalog.model(modelID) ?? catalog.preferred }
    private var family: ModelFamily { model?.family ?? .qwenImage2512 }
    private var styles: [StylePreset] { catalog.styles(for: family) }
    private var style: StylePreset? { styles.first { $0.id == styleID } }
    private var loras: [LoraFile] { catalog.loras(for: family) }
    private var qualities: [Quality] { SamplerPlan.qualities(family, catalog: catalog) }
    private var trimmed: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why Generate can't run now, if it can't.
    private var blocker: String? {
        guard center.catalogLoaded else { return "Reading your models…" }
        guard let model else { return "No image models found in \(Settings.modelsFolder.path)." }
        if let missing = model.missing { return "\(model.title) needs \(missing)." }
        if model.needsReference && references.isEmpty { return "Add 1 to 3 reference images to edit (drop them here)." }
        if trimmed.isEmpty { return "" }
        return nil
    }

    var body: some View {
        if presentation == .window {
            content
                .background(.background)
                .pluginWindowCommands { commands() }
                .task { await appear() }
                .onChange(of: center.catalogLoaded) { _, _ in settle() }
                .onChange(of: modelID) { _, _ in settle() }
        } else {
            scaffold
                .task { await appear() }
                .onChange(of: center.catalogLoaded) { _, _ in settle() }
                .onChange(of: modelID) { _, _ in settle() }
        }
    }

    private func appear() async {
        restore()
        if !center.catalogLoaded || catalog.models.isEmpty { center.refreshCatalog() }
        try? await Task.sleep(nanoseconds: 120_000_000)
        promptFocused = true
    }

    private var scaffold: some View {
        PluginScaffold(
            navigator: nav,
            primaryActionLabel: blocker == nil ? "Generate" : "",
            commands: commands,
            commandTitle: { "ImageGen" },
            listKey: { key in
                guard key == .submit, !nav.canPop else { return false }
                generate()
                return true
            },
            escape: {
                guard showAdvanced, !nav.canPop else { return false }
                showAdvanced = false
                return true
            },
            route: { PluginRoute(payload: [:], title: "ImageGen", icon: .symbol("photo.badge.plus")) }
        ) {
            content
        }
    }

    private var content: some View {
            VStack(spacing: 0) {
                promptField
                optionsBar
                if showAdvanced { advanced }
                if model?.needsReference == true || !references.isEmpty { referenceStrip }
                statusLine
                Divider().opacity(0.5)
                ActivityList(center: center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: drop)
            .overlay { if dropTargeted { dropOverlay } }
    }

    // MARK: Prompt

    private var promptField: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .padding(.top, 3)
            TextField("Describe the image you want · ⇧↩ for a new line", text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .lineLimit(2...6)
                .focused($promptFocused)
                .onKeyPress(.return, phases: .down) { press in
                    guard presentation == .window, press.modifiers.isEmpty else { return .ignored }
                    generate()
                    return .handled
                }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    // MARK: Options

    private var optionsBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(catalog.models) { m in
                    Button { modelID = m.id } label: {
                        Text(m.title + (m.id == model?.id ? "  ✓" : ""))
                        Text(m.detail)
                    }
                    .disabled(!m.usable)
                }
                Divider()
                Button("Refresh Model List") { center.refreshCatalog() }
            } label: {
                Chip(icon: "cpu", text: model?.title ?? "No models")
            }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).fixedSize()

            Menu {
                ForEach(AspectRatio.allCases) { a in
                    Button { aspect = a } label: {
                        Text(a.label + (a == aspect ? "  ✓" : ""))
                        let (w, h) = a.size(for: family, draft: draft)
                        Text("\(w) × \(h)")
                    }
                }
            } label: {
                Chip(icon: aspectIcon, text: aspect.rawValue + (draft ? " · Draft" : ""))
            }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).fixedSize()

            if qualities.count > 1 {
                Menu {
                    ForEach(qualities) { q in
                        Button { quality = q } label: {
                            Text(q.label + (q == quality ? "  ✓" : ""))
                            Text("\(SamplerPlan.plan(family, q, catalog: catalog).steps) steps")
                        }
                    }
                } label: {
                    Chip(icon: "dial.medium", text: quality.label)
                }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).fixedSize()
            }

            if !styles.isEmpty {
                Menu {
                    Button("No Style" + (styleID == nil ? "  ✓" : "")) { styleID = nil }
                    ForEach(styleGroups, id: \.0) { title, items in
                        Section(title) {
                            ForEach(items) { s in
                                Button(s.title + (s.id == styleID ? "  ✓" : "")) { styleID = s.id }
                            }
                        }
                    }
                    Divider()
                    Button("Edit Your Styles…") { editStyles() }
                } label: {
                    Chip(icon: "paintpalette", text: style?.title ?? "Style")
                }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).fixedSize()
            }

            Menu {
                ForEach(1...4, id: \.self) { n in
                    Button("\(n) image\(n == 1 ? "" : "s")" + (n == count ? "  ✓" : "")) { count = n }
                }
            } label: {
                Chip(icon: "square.stack", text: "×\(count)")
            }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).fixedSize()

            Spacer(minLength: 0)

            Button { withAnimation(.easeOut(duration: 0.15)) { showAdvanced.toggle() } } label: {
                Chip(icon: "slider.horizontal.3", text: "More", active: showAdvanced)
            }
            .buttonStyle(.plain)
            .help("Negative prompt, seed, size and LoRA")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var styleGroups: [(String, [StylePreset])] {
        [("Your Styles", StylePreset.Group.custom), ("Looks", .look), ("LoRA Styles · \(model?.title ?? "")", .lora)]
            .map { title, group in (title, styles.filter { $0.group == group }) }
            .filter { !$0.1.isEmpty }
    }

    private func editStyles() {
        NSWorkspace.shared.open(Styles.ensureCustomFile())
        notice = "Save styles.json, then choose Refresh Model List (⌘K) to see your styles."
    }

    private var aspectIcon: String {
        let (w, h) = aspect.ratio
        return w == h ? "square" : (w < h ? "rectangle.portrait" : "rectangle")
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Avoid").foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                TextField("Things to keep out, e.g. blurry, extra fingers", text: $negative)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 10) {
                Text("Seed").foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                TextField("Random", text: $seedText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                Toggle("Draft size (faster)", isOn: $draft).toggleStyle(.checkbox)
                Spacer()
                let (w, h) = aspect.size(for: family, draft: draft)
                Text("\(w) × \(h)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            if !loras.isEmpty {
                HStack(spacing: 10) {
                    Text("LoRA").foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                    Picker("", selection: $loraID) {
                        Text("None").tag(String?.none)
                        ForEach(loras) { l in Text(l.title).tag(Optional(l.id)) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    if loraID != nil {
                        Slider(value: $loraStrength, in: 0.2...1.5)
                            .frame(width: 140)
                        Text(String(format: "%.2f", loraStrength))
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
        .transition(.opacity)
    }

    // MARK: References

    private var referenceStrip: some View {
        HStack(spacing: 8) {
            ForEach(references, id: \.self) { url in
                ZStack(alignment: .topTrailing) {
                    Thumbnail(url: url, side: 52)
                    Button { references.removeAll { $0 == url } } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 4, y: -4)
                }
            }
            if references.count < 3 {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .foregroundStyle(.tertiary)
                    .frame(width: 52, height: 52)
                    .overlay(Image(systemName: "plus").foregroundStyle(.tertiary))
                    .help("Drop images here, or select them in Finder before opening ImageGen")
            }
            Text(model?.needsReference == true
                 ? "Reference images: \(model?.title ?? "") restyles or edits these."
                 : "Reference images are only used by Qwen-Image-Edit.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
            .background(Color.accentColor.opacity(0.06))
            .overlay(Text("Drop images to use as references").font(.headline))
            .padding(8)
            .allowsHitTesting(false)
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, Self.isImage(url) else { return }
                Task { @MainActor in addReferences([url]) }
            }
        }
        return true
    }

    private func addReferences(_ urls: [URL]) {
        for url in urls where !references.contains(url) && references.count < 3 { references.append(url) }
        if let edit = catalog.models.first(where: { $0.needsReference && $0.usable }), model?.needsReference != true {
            notice = "Reference images need \(edit.title): pick it in the model menu (⌘K › Edit Reference Images)."
        }
    }

    static func isImage(_ url: URL) -> Bool {
        (UTType(filenameExtension: url.pathExtension)?.conforms(to: .image)) ?? false
    }

    // MARK: Status

    @ViewBuilder
    private var statusLine: some View {
        let text = notice ?? blocker.flatMap { $0.isEmpty ? nil : $0 }
        if let text {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                Text(text).lineLimit(2)
                Spacer()
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
        }
    }

    // MARK: Actions

    private func generate() {
        guard blocker == nil, let model else {
            if blocker == "" { promptFocused = true }
            return
        }
        var uses = style?.loras ?? []
        if let loraID, !uses.contains(where: { $0.file == loraID }) { uses.append(LoraUse(file: loraID, strength: loraStrength)) }
        let request = GenerationRequest(
            prompt: trimmed,
            negative: [negative, style?.negative ?? ""].filter { !$0.isEmpty }.joined(separator: ", "), modelID: model.id, modelTitle: model.title,
            family: model.family, loader: model.loader, aspect: aspect,
            quality: qualities.contains(quality) ? quality : (qualities.first ?? .standard),
            draft: draft, styleID: style?.id, loras: uses, trigger: style?.trigger ?? "", suffix: style?.suffix ?? "",
            seed: Int(seedText.trimmingCharacters(in: .whitespaces)), count: count,
            references: model.needsReference ? references.map(\.path) : [], safe: Settings.safeMode)
        center.enqueue(request)
        remember()
        notice = nil
        if Settings.closeOnGenerate && presentation != .window {
            closeLauncher()
        } else {
            prompt = ""
        }
    }

    /// Puts a past job's settings back in the form.
    private func reuse(_ job: Job) {
        let r = job.request
        prompt = r.prompt
        negative = r.negative
        modelID = r.modelID
        aspect = r.aspect
        quality = r.quality
        draft = r.draft
        styleID = r.styleID
        count = r.count
        seedText = job.seeds.first.map(String.init) ?? ""
        references = r.references.map { URL(fileURLWithPath: $0) }
        promptFocused = true
    }

    private func commands() -> [PluginCommand] {
        var list: [PluginCommand] = []
        if blocker == nil {
            list.append(PluginCommand(title: "Generate", icon: .symbol("sparkles"), shortcut: "↩") { generate() })
        }
        if let running = center.running {
            list.append(PluginCommand(title: "Cancel Current Image", subtitle: running.request.prompt,
                                      icon: .symbol("stop.circle")) { center.cancel(running.id) })
        }
        if let last = center.jobs.first {
            list.append(PluginCommand(title: "Reuse Last Settings", subtitle: last.request.prompt,
                                      icon: .symbol("arrow.uturn.backward")) { reuse(last) })
        }
        if let latest = center.jobs.first(where: { !$0.outputs.isEmpty }) {
            list.append(PluginCommand(title: "Show Latest Image in Finder", icon: .symbol("folder")) {
                NSWorkspace.shared.activateFileViewerSelecting(latest.outputURLs)
            })
        }
        if !finderImages.isEmpty {
            list.append(PluginCommand(title: "Use Finder Selection as References",
                                      subtitle: finderImages.map(\.lastPathComponent).joined(separator: ", "),
                                      icon: .symbol("photo.on.rectangle")) { addReferences(finderImages) })
        }
        if let edit = catalog.models.first(where: { $0.needsReference && $0.usable }), model?.id != edit.id {
            list.append(PluginCommand(title: "Edit Reference Images", subtitle: "Switch to \(edit.title)",
                                      icon: .symbol("wand.and.stars")) { modelID = edit.id })
        }
        if !references.isEmpty {
            list.append(PluginCommand(title: "Clear References", icon: .symbol("xmark.circle")) { references = [] })
        }
        list.append(PluginCommand(title: "Open Output Folder", subtitle: Settings.outputFolder.path,
                                  icon: .symbol("folder")) {
            try? FileManager.default.createDirectory(at: Settings.outputFolder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(Settings.outputFolder)
        })
        list.append(PluginCommand(title: showAdvanced ? "Hide More Options" : "Show More Options",
                                  icon: .symbol("slider.horizontal.3")) { showAdvanced.toggle() })
        list.append(PluginCommand(title: "Edit Your Styles", subtitle: "styles.json: name, before, after, avoid",
                                  icon: .symbol("paintpalette")) { editStyles() })
        list.append(PluginCommand(title: "Refresh Model List", icon: .symbol("arrow.clockwise")) { center.refreshCatalog() })
        if center.jobs.contains(where: { !$0.isActive }) {
            list.append(PluginCommand(title: "Clear Finished from History", subtitle: "The images stay on disk",
                                      icon: .symbol("trash")) { center.clearFinished() })
        }
        list.append(PluginCommand(title: "Open ComfyUI in Browser", icon: .symbol("safari")) {
            NSWorkspace.shared.open(Settings.serverURL)
        })
        return list
    }

    // MARK: Remembering choices

    private func restore() {
        modelID = Settings.remembered("model")
        aspect = Settings.remembered("aspect").flatMap(AspectRatio.init(rawValue:)) ?? .story
        quality = Settings.remembered("quality").flatMap(Quality.init(rawValue:)) ?? .standard
        styleID = Settings.remembered("style")
        draft = Settings.remembered("draft") == "true"
        count = Settings.remembered("count").flatMap(Int.init) ?? 1
        let selected = finderImages.prefix(3)
        if !selected.isEmpty, references.isEmpty { references = Array(selected) }
    }

    private func remember() {
        Settings.remember(model?.id, "model")
        Settings.remember(aspect.rawValue, "aspect")
        Settings.remember(quality.rawValue, "quality")
        Settings.remember(styleID, "style")
        Settings.remember(draft ? "true" : "false", "draft")
        Settings.remember(String(count), "count")
    }

    /// Keeps the choices valid for the model on screen: a style or LoRA from another base is dropped,
    /// a quality the model doesn't offer falls back.
    private func settle() {
        guard center.catalogLoaded else { return }
        if catalog.model(modelID) == nil { modelID = catalog.preferred?.id }
        if let styleID, !styles.contains(where: { $0.id == styleID }) { self.styleID = nil }
        if let loraID, !loras.contains(where: { $0.id == loraID }) { self.loraID = nil }
        if !qualities.contains(quality) { quality = qualities.contains(.standard) ? .standard : (qualities.first ?? .standard) }
        if model?.needsReference == true, references.isEmpty, !finderImages.isEmpty {
            references = Array(finderImages.prefix(3))
        }
        notice = nil
    }
}

// MARK: - Activity

struct ActivityList: View {
    let center: JobCenter

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if center.jobs.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 28)).foregroundStyle(.tertiary)
                        Text("Your images appear here. They keep rendering in the background after you close the launcher.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: 360)
                    .padding(.top, 36)
                } else {
                    ForEach(center.jobs) { job in
                        JobRow(job: job, live: center.live[job.id], center: center)
                        Divider().opacity(0.3).padding(.leading, 86)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .contentMargins(.bottom, 52, for: .scrollContent)
    }
}

struct JobRow: View {
    let job: Job
    let live: LiveProgress?
    let center: JobCenter
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            preview
            VStack(alignment: .leading, spacing: 4) {
                Text(job.request.prompt).font(.system(size: 13)).lineLimit(1)
                status
            }
            Spacer(minLength: 8)
            actions.opacity(hovered || job.isActive ? 1 : 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(hovered ? Color.primary.opacity(0.05) : .clear)
        .onHover { hovered = $0 }
        .onTapGesture { if !job.outputs.isEmpty { job.outputURLs.forEach { NSWorkspace.shared.open($0) } } }
        .help(job.outputs.isEmpty ? job.request.prompt : "Click to open · " + job.request.prompt)
    }

    private var preview: some View {
        ZStack {
            if let first = job.outputURLs.first {
                Thumbnail(url: first, side: 58)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)).frame(width: 58, height: 58)
                    .overlay {
                        switch job.state {
                        case .failed: Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        case .cancelled: Image(systemName: "xmark").foregroundStyle(.secondary)
                        default: ProgressView().controlSize(.small)
                        }
                    }
            }
            if job.outputs.count > 1 {
                Text("\(job.outputs.count)").font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(3)
            }
        }
        .frame(width: 58, height: 58)
    }

    @ViewBuilder
    private var status: some View {
        let meta = "\(job.request.modelTitle) · \(job.request.aspect.rawValue)"
        switch job.state {
        case .running:
            VStack(alignment: .leading, spacing: 4) {
                if let fraction = live?.fraction {
                    ProgressView(value: fraction).progressViewStyle(.linear).frame(maxWidth: 260)
                }
                Text([live?.phase ?? "Starting", live?.remaining.map { JobCenter.duration($0) + " left" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .queued:
            Text("Queued · " + meta).font(.system(size: 11)).foregroundStyle(.secondary)
        case .done:
            Text(meta + (job.seconds.map { " · " + JobCenter.duration($0) } ?? "") + " · " + Self.ago(job.finished ?? job.created))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        case .failed:
            Text(job.error ?? "Failed").font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
        case .cancelled:
            Text("Cancelled · " + meta).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 4) {
            if job.isActive {
                IconButton(symbol: "stop.circle", help: "Cancel") { center.cancel(job.id) }
            } else {
                if !job.outputs.isEmpty {
                    IconButton(symbol: "doc.on.doc", help: "Copy image") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.writeObjects(job.outputURLs.compactMap { NSImage(contentsOf: $0) })
                    }
                    IconButton(symbol: "folder", help: "Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(job.outputURLs)
                    }
                }
                IconButton(symbol: "arrow.clockwise", help: "Run again with a new seed") {
                    var again = job.request
                    again.seed = nil
                    center.enqueue(again)
                }
                IconButton(symbol: "xmark", help: "Remove from history (the files stay)") { center.remove(job.id) }
            }
        }
    }

    static func ago(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Small pieces

struct Chip: View {
    let icon: String
    let text: String
    var active = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11, weight: .medium))
            Text(text).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Color.primary.opacity(active ? 0.14 : 0.07), in: Capsule())
        .foregroundStyle(active ? .primary : .secondary)
        .contentShape(Capsule())
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.07), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A square thumbnail, decoded small off the main thread and cached.
struct Thumbnail: View {
    let url: URL
    let side: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.primary.opacity(0.06)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: url) { image = await ThumbnailCache.shared.image(url, pixels: Int(side * 2)) }
    }
}

final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    func image(_ url: URL, pixels: Int) async -> NSImage? {
        let key = "\(url.path)#\(pixels)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let made = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixels,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary)
            else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let made { cache.setObject(made, forKey: key) }
        return made
    }
}
