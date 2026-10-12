# Hello — a sample native Onecast plugin

A worked example of a **native Swift plugin** for Onecast (distinct from the JavaScript Raycast
extensions in the sibling folders). It demonstrates every row shape:

- **Say Hello** — a headless `.run` action that shows a HUD message.
- **Open Counter** — a `.surface` action that hosts a live, stateful SwiftUI view in the palette.
- **Browse Colors** — a `.children` action that drills into a sub-list.
- **Open Onecast on GitHub** — an `.openURL` action.

The full authoring guide and invariants are in [`SWIFT_PLUGINS.md`](../SWIFT_PLUGINS.md); the app's
end-to-end develop/build/install reference is `docs/plugins_and_extensions.md` in the Onecast repo.

## Install

There is no build step — Onecast compiles the plugin from source. Copy `manifest.json` and the
`.swift` beside it into the app's plugins folder:

```sh
DEST="$HOME/Library/Application Support/com.onecast.app.dev/plugins/hello"
mkdir -p "$DEST" && cp manifest.json HelloPlugin.swift "$DEST/"
```

Then, in Onecast: **Settings → Plugins → Enable plugins**, open the launcher, and search **Hello**.
The app builds the sources against its own embedded `OnecastPluginKit`, ad-hoc signs the result, and
caches it; editing a source and reopening the plugin rebuilds it with no app relaunch.

Building needs a Swift toolchain (Xcode or the Command Line Tools). A compile error surfaces in the
palette where the plugin would run.

## Layout

```
hello/
  manifest.json                     name, identifier, subtitle, icon
  HelloPlugin.swift                 the whole plugin, beside the manifest
```

## Anatomy of a plugin

Conform an `NSObject` subclass to `OnecastPlugin`, declare `override init() { super.init() }`
(NSObject's inherited `init()` does not satisfy the protocol on its own), and export the loader
handshake:

```swift
@_cdecl("onecastPluginCreate")
public func onecastPluginCreate() -> UnsafeMutableRawPointer {
    OnecastPluginRuntime.export { HelloPlugin() }
}
```

`results(for:)` is re-asked on every keystroke, so filter on `context.query`. `perform`/`children`
are `async` — do slow work there. A `.surface` view owns the whole palette body; Escape pops back
to the list, then out.
