import AppKit
import SwiftUI
import OnecastPluginKit

/// A sample native Onecast plugin. Shows every shape a row can take: a headless action, a
/// SwiftUI surface, a drill-in child list, and an external link.
final class HelloPlugin: NSObject, OnecastPlugin {
    static let metadata = PluginMetadata(
        name: "Hello",
        subtitle: "A sample native plugin",
        icon: "hand.wave")

    override init() { super.init() }

    func results(for context: PluginContext) -> [PluginResult] {
        let rows = [
            PluginResult(
                id: "greet",
                title: "Say Hello",
                subtitle: "Show a message in the HUD",
                icon: .symbol("hand.wave"),
                keywords: ["hi", "hello", "greet"],
                action: .run(id: "greet")),
            PluginResult(
                id: "counter",
                title: "Open Counter",
                subtitle: "A live SwiftUI surface",
                icon: .symbol("number.circle"),
                keywords: ["count", "surface", "swiftui"],
                action: .surface(id: "counter")),
            PluginResult(
                id: "colors",
                title: "Browse Colors",
                subtitle: "Drill into a child list",
                icon: .symbol("paintpalette"),
                keywords: ["color", "list", "children"],
                action: .children(id: "colors")),
            PluginResult(
                id: "repo",
                title: "Open Onecast on GitHub",
                subtitle: "github.com/abue-ammar/onecast",
                icon: .symbol("link"),
                keywords: ["github", "repo", "url"],
                action: .openURL(URL(string: "https://github.com/abue-ammar/onecast")!)),
        ]

        let query = context.query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return rows }
        return rows.filter { row in
            row.title.lowercased().contains(query)
                || (row.subtitle?.lowercased().contains(query) ?? false)
                || row.keywords.contains { $0.contains(query) }
        }
    }

    func children(of resultID: String, context: PluginContext) async -> [PluginResult] {
        guard resultID == "colors" else { return [] }
        return ["Red", "Orange", "Green", "Blue", "Purple"].map { name in
            PluginResult(
                id: "color-\(name)",
                title: name,
                subtitle: "Copy “\(name)” to the clipboard",
                icon: .symbol("circle.fill"),
                keywords: [name.lowercased()],
                action: .run(id: "copy-\(name)"))
        }
    }

    func perform(resultID: String, context: PluginContext) async -> PluginActionResult {
        switch resultID {
        case "greet":
            let who = context.frontmostAppBundleID.map { " (from \($0))" } ?? ""
            return PluginActionResult(
                closesLauncher: true, message: "Hello from a native plugin!\(who)")
        case let id where id.hasPrefix("copy-"):
            let name = String(id.dropFirst("copy-".count))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(name, forType: .string)
            return PluginActionResult(closesLauncher: true, message: "Copied \(name)")
        default:
            return .close
        }
    }

    func surface(for resultID: String, context: PluginContext) -> AnyView {
        AnyView(CounterScreen())
    }
}

/// Wraps the counter in a `PluginScaffold`, so Escape leaves the surface and the footer reads right.
private struct CounterScreen: View {
    @State private var navigator = PluginNavigator()
    var body: some View {
        PluginScaffold(navigator: navigator) { CounterView() }
    }
}

/// A trivial stateful SwiftUI view, to prove a plugin owns a real, interactive palette body.
private struct CounterView: View {
    @State private var count = 0

    var body: some View {
        VStack(spacing: 16) {
            Text("Counter")
                .font(.title2.bold())
            Text("\(count)")
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .monospacedDigit()
            HStack(spacing: 16) {
                Button { count -= 1 } label: { Image(systemName: "minus.circle.fill") }
                Button { count += 1 } label: { Image(systemName: "plus.circle.fill") }
            }
            .font(.largeTitle)
            .buttonStyle(.plain)
            Text("Rendered by the plugin, hosted in Onecast's palette.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

/// The loader handshake: the host `dlsym`s this symbol, calls it once on the main thread, and
/// casts the result to `OnecastPlugin`. Every plugin exports exactly this.
@_cdecl("onecastPluginCreate")
public func onecastPluginCreate() -> UnsafeMutableRawPointer {
    OnecastPluginRuntime.export { HelloPlugin() }
}
