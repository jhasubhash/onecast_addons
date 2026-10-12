import OnecastPluginKit
import SwiftUI

/// One LeetCode problem a day: the tile shows the streak and whether today is done, the popover
/// the problem, a link to solve it, and the game around it — XP, levels, freezes, badges and a
/// heatmap.
final class LeetCodeWidget: OnecastDockWidget {
    static let metadata = DockWidgetMetadata(
        name: "LeetCode",
        subtitle: "A problem a day, with streaks",
        icon: "flame",
        category: "Productivity",
        sizes: [.compact, .wide, .expanded])

    private let model = LCModel()
    private var applied = false

    required init() {}

    func tile(context: DockWidgetContext) -> AnyView {
        sync(context)
        return AnyView(LCTile(model: model, context: context))
    }

    func popover(context: DockWidgetContext) -> AnyView? {
        sync(context)
        return AnyView(LCPopover(model: model, context: context))
    }

    func didRemove() {
        model.stop()
    }

    /// The host re-asks after every preference edit, so this is where settings reach the model.
    /// The first call applies at once; later ones may come from inside a view update, so they hop
    /// off it first.
    private func sync(_ context: DockWidgetContext) {
        if !applied {
            applied = true
            model.apply(context)
        } else {
            Task { @MainActor [model] in model.apply(context) }
        }
    }
}

@_cdecl("onecastDockWidgetCreate")
public func onecastDockWidgetCreate() -> UnsafeMutableRawPointer {
    OnecastDockWidgetRuntime.export { LeetCodeWidget() }
}
