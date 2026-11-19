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
    @State private var referenceMode: ReferenceMode = .variation
    @State private var strength = 0.7
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
    private var modes: [ReferenceMode] { family.referenceModes }
    /// The mode in effect: the chosen one when this model has it, else the model's own.
    private var mode: ReferenceMode { modes.contains(referenceMode) ? referenceMode : (modes.first ?? .variation) }
    private var maxReferences: Int { family.maxReferences(mode) }
    static let referenceLimit = 6

    /// Why Generate can't run now, if it can't.
    private var blocker: String? {
        guard center.catalogLoaded else { return "Reading your models…" }
        guard let model else { return "No image models found in \(Settings.modelsFolder.path)." }
        if let missing = model.missing { return "\(model.title) needs \(missing)." }
        if model.needsReference && references.isEmpty {
            return "\(model.title) edits pictures: add 1 to 3 with +, ⌘V or by dropping them here."
        }
        if !references.isEmpty, mode == .style || mode == .face, !catalog.ipAdapter {
            return "IP-Adapter isn't installed (ComfyUI_IPAdapter_plus and its SDXL models)."
        }
        if trimmed.isEmpty { return "" }
        return nil
    }

    var body: some View {
        if presentation == .window {
            windowContent
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
                ActivityList(center: center, load: reuse)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted, perform: drop)
            .overlay { if dropTargeted { dropOverlay } }
            .background(PasteCatcher { pasteReferences() })
    }

    /// The popped-out window reads like a chat: results flow down the window, newest at the bottom, and the
    /// composer (references, prompt, options) sits at the bottom edge.
    private var windowContent: some View {
        VStack(spacing: 0) {
            windowHeader
            Divider().opacity(0.5)
            ChatList(center: center, load: reuse, useAsReference: { addReferences([$0]) })
            Divider().opacity(0.5)
            VStack(spacing: 0) {
                if showAdvanced { advanced.padding(.top, 10) }
                if model?.needsReference == true || !references.isEmpty { referenceStrip.padding(.top, 10) }
                promptField
                optionsBar
                statusLine
            }
            .background(Color.primary.opacity(0.03))
        }
        .frame(minWidth: 520, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted, perform: drop)
        .overlay { if dropTargeted { dropOverlay } }
        .background(PasteCatcher { pasteReferences() })
    }

    /// A plain title bar: no controls, so the whole strip is background the window is dragged by.
    private var windowHeader: some View {
        ZStack {
            WindowDragArea()
            HStack(spacing: 6) {
                Image(systemName: "photo.badge.plus").font(.system(size: 12)).foregroundStyle(.secondary)
                Text("ImageGen").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                if let busy = activeSummary {
                    Text("· " + busy).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .allowsHitTesting(false)
            HStack {
                TrafficLights(close: closeLauncher)
                Spacer()
            }
            .padding(.leading, 14)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 36)
    }

    private var activeSummary: String? {
        let running = center.jobs.filter { $0.state == .running }.count
        let queued = center.jobs.filter { $0.state == .queued }.count
        let parts = [running > 0 ? "rendering" : nil, queued > 0 ? "\(queued) queued" : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    // MARK: Prompt

    private var canSend: Bool {
        blocker == nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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
            Button(action: generate) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Generate (↩)")
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

            Button { pickReferences() } label: {
                Chip(icon: "photo.on.rectangle", text: references.isEmpty ? "Reference" : "\(references.count) Ref",
                     active: !references.isEmpty)
            }
            .buttonStyle(.plain)
            .help("Add reference images: click to choose, or paste (⌘V) or drop them here")

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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(Array(references.enumerated()), id: \.element) { index, url in
                    ZStack(alignment: .topTrailing) {
                        Thumbnail(url: url, side: 52)
                            .opacity(index < maxReferences ? 1 : 0.35)
                            .overlay(alignment: .bottomLeading) {
                                // The number the prompt refers to ("the woman in image 1")
                                Text("\(index + 1)").font(.system(size: 10, weight: .bold)).monospacedDigit()
                                    .frame(minWidth: 16, minHeight: 16)
                                    .background(.black.opacity(0.65), in: Circle()).foregroundStyle(.white)
                                    .padding(3)
                            }
                            .help(index < maxReferences
                                  ? "Image \(index + 1): \(url.lastPathComponent) · right-click to reorder"
                                  : "Not used: \(model?.title ?? "") reads \(maxReferences)")
                            .contextMenu {
                                if index > 0 {
                                    Button("Make Image 1") { moveReference(url, to: 0) }
                                    Button("Move Left") { moveReference(url, to: index - 1) }
                                }
                                if index < references.count - 1 {
                                    Button("Move Right") { moveReference(url, to: index + 1) }
                                }
                                if references.count == 2 {
                                    Button("Swap Images 1 and 2") { references.swapAt(0, 1) }
                                }
                                Divider()
                                Button("Remove") { references.removeAll { $0 == url } }
                            }
                        Button { references.removeAll { $0 == url } } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 4, y: -4)
                        .accessibilityLabel("Remove reference")
                    }
                }
                if references.count < Self.referenceLimit {
                    Button { pickReferences() } label: {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                            .foregroundStyle(.tertiary)
                            .frame(width: 52, height: 52)
                            .overlay(Image(systemName: "plus").foregroundStyle(.secondary))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Choose images · or paste (⌘V) or drop them here")
                    .accessibilityLabel("Add reference image")
                }
                if !references.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if modes.count > 1 {
                            Picker("", selection: $referenceMode) {
                                ForEach(modes) { m in Text(m.label).tag(m) }
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                        }
                        if mode != .edit {
                            HStack(spacing: 6) {
                                Text(mode == .variation ? "Change" : "Strength").foregroundStyle(.secondary)
                                Slider(value: $strength, in: mode == .variation ? 0.15...0.95 : 0.2...1.2).frame(width: 130)
                                Text(String(format: "%.2f", strength)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.system(size: 12))
                }
                Spacer(minLength: 0)
            }
            Text(referenceCaption).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private var referenceCaption: String {
        if references.isEmpty {
            return "\(model?.title ?? "This model") edits the pictures you add: + to choose, ⌘V to paste, or drop them here."
        }
        var text = mode.help
        if mode == .edit && references.count > 1 {
            text += " Name them by number and say what to keep and what to change, e.g. \"Keep the woman from image 1 exactly; change only her clothes to the outfit in image 2\"."
        }
        if mode == .edit { text += references.count == 1 ? " One picture keeps its own size." : " Drawn at \(aspect.rawValue)." }
        if references.count > maxReferences {
            text += " \(model?.title ?? "") reads the first \(maxReferences == 1 ? "one" : String(maxReferences))."
        }
        return text
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
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL, Self.isImage(url) else { return }
                    Task { @MainActor in addReferences([url]) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {  // an image dragged from a browser
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let image = image as? NSImage else { return }
                    Task { @MainActor in if let url = Self.savePasted(image) { addReferences([url]) } }
                }
            }
        }
        return true
    }

    private func addReferences(_ urls: [URL]) {
        for url in urls where !references.contains(url) && references.count < Self.referenceLimit { references.append(url) }
        notice = nil
    }

    private func moveReference(_ url: URL, to index: Int) {
        guard let from = references.firstIndex(of: url) else { return }
        references.remove(at: from)
        references.insert(url, at: min(max(index, 0), references.count))
    }

    private func pickReferences() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose up to \(Self.referenceLimit - references.count) reference images"
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        addReferences(panel.urls)
    }

    /// ⌘V with a picture on the clipboard: image files copied in Finder, or image data (a screenshot,
    /// Copy Image in a browser). Copied text is left to the prompt field. Returns whether it took it.
    private func pasteReferences() -> Bool {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let images = urls.filter(Self.isImage)
            if !images.isEmpty { addReferences(images); return true }
            if !urls.isEmpty { return false }
        }
        guard pb.string(forType: .string) == nil, let image = NSImage(pasteboard: pb), let url = Self.savePasted(image)
        else { return false }
        addReferences([url])
        return true
    }

    /// Pasted pictures are kept as PNGs in the plugin's data folder (pasted/), so a job can reuse them.
    static func savePasted(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        let folder = Styles.customFile.deletingLastPathComponent().appendingPathComponent("pasted")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = folder.appendingPathComponent("pasted-\(f.string(from: Date()))-\(UUID().uuidString.prefix(4)).png")
        return (try? png.write(to: url)) == nil ? nil : url
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
            references: references.prefix(maxReferences).map(\.path), safe: Settings.safeMode,
            referenceMode: references.isEmpty ? nil : mode, strength: references.isEmpty || mode == .edit ? nil : strength)
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
    /// Puts a past job's prompt, references and settings back in the form to edit before running it again.
    /// The seed is left random, so a run after an edit isn't tied to the old one.
    private func reuse(_ job: Job) {
        let r = job.request
        prompt = r.prompt
        modelID = r.modelID
        aspect = r.aspect
        quality = r.quality
        draft = r.draft
        styleID = r.styleID
        count = r.count
        seedText = ""
        // The job's negative and LoRAs include the style's own; keep only what was added by hand.
        let styleNegative = catalog.styles.first { $0.id == r.styleID }?.negative ?? ""
        var own = r.negative
        if !styleNegative.isEmpty, own.hasSuffix(styleNegative) {
            own = String(own.dropLast(styleNegative.count)).trimmingCharacters(in: CharacterSet(charactersIn: ", "))
        }
        negative = own
        let styleLoras = Set((catalog.styles.first { $0.id == r.styleID }?.loras ?? []).map(\.file))
        if let extra = r.loras.first(where: { !styleLoras.contains($0.file) }) {
            loraID = extra.file
            loraStrength = extra.strength
        } else {
            loraID = nil
        }
        let files = r.references.map { URL(fileURLWithPath: $0) }
        references = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        if let m = r.referenceMode { referenceMode = m }
        if let v = r.strength { strength = v }
        if !negative.isEmpty || loraID != nil { showAdvanced = true }
        let missing = files.count - references.count
        let note = missing > 0
            ? "Loaded, but \(missing) reference image\(missing == 1 ? " is" : "s are") no longer on disk."
            : "Loaded. Edit anything, then press Return to run it."
        promptFocused = true
        Task { @MainActor in  // after the model change has settled, which clears the status line
            try? await Task.sleep(nanoseconds: 80_000_000)
            notice = note
        }
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
        list.append(PluginCommand(title: "Add Reference Images…", subtitle: "Or paste (⌘V) or drop them here",
                                  icon: .symbol("photo.on.rectangle")) { pickReferences() })
        if let edit = catalog.models.first(where: { $0.family == .qwenImage21 && $0.usable })
            ?? catalog.models.first(where: { $0.needsReference && $0.usable }), model?.id != edit.id {
            list.append(PluginCommand(title: "Edit Reference Images", subtitle: "Switch to \(edit.title)",
                                      icon: .symbol("wand.and.stars")) { modelID = edit.id })
        }
        if references.count == 2 {
            list.append(PluginCommand(title: "Swap Reference Images 1 and 2", icon: .symbol("arrow.left.arrow.right")) {
                references.swapAt(0, 1)
            })
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
        referenceMode = Settings.remembered("referenceMode").flatMap(ReferenceMode.init(rawValue:)) ?? .variation
        strength = Settings.remembered("strength").flatMap(Double.init) ?? 0.7
        let selected = finderImages.prefix(Self.referenceLimit)
        if !selected.isEmpty, references.isEmpty { references = Array(selected) }
    }

    private func remember() {
        Settings.remember(model?.id, "model")
        Settings.remember(aspect.rawValue, "aspect")
        Settings.remember(quality.rawValue, "quality")
        Settings.remember(styleID, "style")
        Settings.remember(draft ? "true" : "false", "draft")
        Settings.remember(String(count), "count")
        Settings.remember(referenceMode.rawValue, "referenceMode")
        Settings.remember(String(strength), "strength")
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
            references = Array(finderImages.prefix(Self.referenceLimit))
        }
        notice = nil
    }
}

// MARK: - Activity

struct ActivityList: View {
    let center: JobCenter
    /// Loads a job's settings into the form.
    let load: (Job) -> Void

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
                        JobRow(job: job, live: center.live[job.id], center: center, load: load)
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
    let load: (Job) -> Void
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
                CancelJobButton { center.cancel(job.id) }
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
                IconButton(symbol: "square.and.pencil", help: "Load this prompt, its references and settings to edit") {
                    load(job)
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

// MARK: - Chat (popped-out window)

/// Every job as a chat exchange, oldest first: the prompt as the user's bubble on the right, the images (or the
/// progress) below on the left. Keeps the newest in view as jobs arrive and finish.
struct ChatList: View {
    let center: JobCenter
    let load: (Job) -> Void
    let useAsReference: (URL) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if center.jobs.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 34)).foregroundStyle(.tertiary)
                            Text("Describe an image below and press Return. Your images appear here and keep rendering in the background.")
                                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: 380).frame(maxWidth: .infinity).padding(.top, 80)
                    }
                    ForEach(center.jobs.reversed()) { job in
                        ChatItem(job: job, live: center.live[job.id], center: center, load: load, useAsReference: useAsReference)
                            .id(job.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: center.jobs.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: center.jobs.first?.outputs.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}

struct ChatItem: View {
    let job: Job
    let live: LiveProgress?
    let center: JobCenter
    let load: (Job) -> Void
    let useAsReference: (URL) -> Void
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            request
            result
        }
        .onHover { hovered = $0 }
    }

    /// The prompt bubble, with the references it used.
    private var request: some View {
        HStack {
            Spacer(minLength: 80)
            VStack(alignment: .trailing, spacing: 6) {
                if !job.request.references.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(job.request.references.enumerated()), id: \.offset) { index, path in
                            Thumbnail(url: URL(fileURLWithPath: path), side: 34)
                                .overlay(alignment: .bottomLeading) {
                                    Text("\(index + 1)").font(.system(size: 9, weight: .bold))
                                        .frame(minWidth: 13, minHeight: 13)
                                        .background(.black.opacity(0.65), in: Circle()).foregroundStyle(.white).padding(2)
                                }
                        }
                    }
                }
                Text(job.request.prompt)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 14))
                Text(meta).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    private var meta: String {
        let r = job.request
        return [r.modelTitle, r.aspect.rawValue, r.mode.map { $0.label }, JobRow.ago(job.created)].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private var result: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !job.outputs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(job.outputURLs, id: \.self) { url in
                            ResultImage(url: url, height: 260)
                                .onTapGesture { NSWorkspace.shared.open(url) }
                                .help("Click to open")
                                .contextMenu {
                                    Button("Open") { NSWorkspace.shared.open(url) }
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                    Button("Copy Image") {
                                        let pb = NSPasteboard.general
                                        pb.clearContents()
                                        if let image = NSImage(contentsOf: url) { pb.writeObjects([image]) }
                                    }
                                    Divider()
                                    Button("Use as Reference") { useAsReference(url) }
                                }
                        }
                    }
                }
            }
            status
            HStack(spacing: 4) {
                if job.isActive {
                    CancelJobButton { center.cancel(job.id) }
                } else {
                    if !job.outputs.isEmpty {
                        IconButton(symbol: "folder", help: "Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting(job.outputURLs)
                        }
                    }
                    IconButton(symbol: "square.and.pencil", help: "Load this prompt, its references and settings to edit") { load(job) }
                    IconButton(symbol: "xmark", help: "Remove from history (the files stay)") { center.remove(job.id) }
                }
            }
            .opacity(hovered || job.isActive ? 1 : 0)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch job.state {
        case .running:
            VStack(alignment: .leading, spacing: 4) {
                if let fraction = live?.fraction {
                    ProgressView(value: fraction).progressViewStyle(.linear).frame(maxWidth: 260)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text([live?.phase ?? "Starting", live?.remaining.map { JobCenter.duration($0) + " left" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .queued:
            Label("Queued", systemImage: "clock").font(.system(size: 11)).foregroundStyle(.secondary)
        case .done:
            Text("\(job.outputs.count) image\(job.outputs.count == 1 ? "" : "s")" + (job.seconds.map { " · " + JobCenter.duration($0) } ?? ""))
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        case .failed:
            Label(job.error ?? "Failed", systemImage: "exclamationmark.triangle")
                .font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
        case .cancelled:
            Label("Cancelled" + (job.outputs.isEmpty ? "" : " · \(job.outputs.count) kept"), systemImage: "xmark.circle")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// A finished image at its own shape, a fixed height, decoded small and cached.
struct ResultImage: View {
    let url: URL
    let height: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Color.primary.opacity(0.06).aspectRatio(9 / 16, contentMode: .fit)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .task(id: url) { image = await ThumbnailCache.shared.image(url, pixels: Int(height * 2.2)) }
    }
}

// MARK: - Window buttons

/// Close, minimise and zoom, drawn like the system's own, for the borderless pop-out window.
struct TrafficLights: View {
    let close: () -> Void
    @State private var hovered = false
    @State private var window: NSWindow?
    @State private var restoreFrame: NSRect?

    var body: some View {
        HStack(spacing: 8) {
            light(.init(red: 1, green: 0.37, blue: 0.34), symbol: "xmark", help: "Close") { close() }
            light(.init(red: 1, green: 0.74, blue: 0.18), symbol: "minus", help: "Minimise") { minimise() }
            light(.init(red: 0.16, green: 0.79, blue: 0.25), symbol: "arrow.up.left.and.arrow.down.right", help: "Zoom") { zoom() }
        }
        .onHover { hovered = $0 }
        .background(WindowReader { window = $0 })
    }

    private func light(_ color: Color, symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .overlay(Circle().strokeBorder(.black.opacity(0.18), lineWidth: 0.5))
                .overlay {
                    if hovered {
                        Image(systemName: symbol).font(.system(size: 7, weight: .heavy)).foregroundStyle(.black.opacity(0.6))
                    }
                }
                .frame(width: 12, height: 12)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func minimise() {
        guard let window else { return }
        // A borderless window can't miniaturise until it's allowed to.
        window.styleMask.insert(.miniaturizable)
        window.miniaturize(nil)
    }

    /// Fills the screen's visible area; a second press puts it back where it was.
    private func zoom() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        if let restoreFrame, window.frame == screen.visibleFrame {
            window.setFrame(restoreFrame, display: true, animate: true)
            self.restoreFrame = nil
        } else {
            restoreFrame = window.frame
            window.setFrame(screen.visibleFrame, display: true, animate: true)
        }
    }
}

/// A press anywhere on it drags the window, as a title bar does.
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Hands back the NSWindow a view is in.
private struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { found(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { found(nsView.window) }
    }
}

/// A labelled Cancel, so stopping a render is as plain as starting one.
struct CancelJobButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label("Cancel", systemImage: "stop.fill")
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Color.red.opacity(0.15), in: Capsule())
                .foregroundStyle(.red)
        }
        .buttonStyle(.plain)
        .help("Stop this job; images already finished are kept")
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

// MARK: - Paste

/// Catches ⌘V in this view's window before the text field does, so a picture on the clipboard
/// becomes a reference. `paste` returns false to let the key through (copied text goes to the prompt).
struct PasteCatcher: NSViewRepresentable {
    let paste: () -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.paste = paste
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator = context.coordinator] event in
            guard let coordinator, let window = coordinator.view?.window, event.window === window,
                event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                event.charactersIgnoringModifiers?.lowercased() == "v"
            else { return event }
            return coordinator.paste() ? nil : event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.paste = paste }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var view: NSView?
        var monitor: Any?
        var paste: () -> Bool = { false }
    }
}

// Window layout: see README, "Popped-out window".
