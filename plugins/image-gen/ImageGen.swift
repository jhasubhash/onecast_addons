import AppKit
import OnecastPluginKit
import SwiftUI

/// ImageGen: type a prompt, pick a local model, an aspect ratio and a few options, and the image
/// renders in the background through ComfyUI. Progress shows in Onecast's HUD pill (a preference)
/// and a finished image is announced in the HUD and on a card with Open and Show in Finder.
final class ImageGenPlugin: NSObject, OnecastPlugin {
    static let metadata = PluginMetadata(
        name: "ImageGen",
        subtitle: "Generate images with your local models",
        icon: "photo.badge.plus")

    override init() { super.init() }

    func bind(services: OnecastHostServices) {
        JobCenter.shared.services = services
    }

    func rootSurface(context: PluginContext) -> AnyView? {
        AnyView(RootView(
            center: JobCenter.shared,
            finderImages: context.finderSelection.filter(RootView.isImage),
            presentation: context.presentation))
    }
}

@_cdecl("onecastPluginCreate")
public func onecastPluginCreate() -> UnsafeMutableRawPointer {
    OnecastPluginRuntime.export { ImageGenPlugin() }
}
