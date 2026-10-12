import Observation
import OnecastPluginKit
import SwiftUI

/// The widget's state. It lives in the widget object, so it is per instance: two Hello tiles on two
/// docks count their waves separately.
@MainActor
@Observable
final class HelloModel {
    var waves = 0
}

/// A sample DockWidget: a compact tile, a wide tile, one preference and a popover.
final class HelloWidget: OnecastDockWidget {
    static let metadata = DockWidgetMetadata(
        name: "Hello",
        subtitle: "A sample DockWidget",
        icon: "hand.wave",
        category: "Examples",
        sizes: [.compact, .wide])

    private let model = HelloModel()

    required init() {}

    func tile(context: DockWidgetContext) -> AnyView {
        AnyView(HelloTile(model: model, context: context))
    }

    func popover(context: DockWidgetContext) -> AnyView? {
        AnyView(HelloPopover(model: model, context: context))
    }

    func didRemove() {
        model.waves = 0
    }
}

/// Read the preference here, not at `init`: the host re-asks `tile(context:)` after every edit in
/// Settings, so a changed greeting shows at once.
private func greeting(_ context: DockWidgetContext) -> String {
    context.preferences.string("greeting") ?? "Hello"
}

private struct HelloTile: View {
    let model: HelloModel
    let context: DockWidgetContext

    var body: some View {
        Group {
            if context.size == .compact {
                wave
            } else {
                // A side dock is narrow and tall, so a wide tile stacks instead of running sideways.
                let layout = context.edge.isVertical
                    ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 8))
                layout {
                    wave
                    VStack(spacing: 2) {
                        Text(greeting(context)).font(.headline).lineLimit(1)
                        Text("\(model.waves) waves").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var wave: some View {
        Image(systemName: "hand.wave.fill")
            .font(.system(size: context.tileLength * 0.4))
            .foregroundStyle(.tint)
    }
}

private struct HelloPopover: View {
    let model: HelloModel
    let context: DockWidgetContext

    var body: some View {
        VStack(spacing: 12) {
            Text(greeting(context)).font(.headline)
            Text("\(model.waves)")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
            HStack {
                Button("Wave") { model.waves += 1 }
                Button("Reset") { model.waves = 0 }
            }
            HStack {
                Button("Onecast on GitHub") {
                    if let url = URL(string: "https://github.com/jhasubhash/onecast") {
                        context.actions.openURL(url)
                    }
                    context.actions.closePopover()
                }
                Button("Settings", action: context.actions.openSettings)
            }
        }
        .padding(16)
        .frame(width: 260)
    }
}

/// The host `dlsym`s this symbol and calls it once per instance, on the main thread.
@_cdecl("onecastDockWidgetCreate")
public func onecastDockWidgetCreate() -> UnsafeMutableRawPointer {
    OnecastDockWidgetRuntime.export { HelloWidget() }
}
