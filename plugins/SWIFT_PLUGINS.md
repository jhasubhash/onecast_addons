# Writing a native SwiftUI plugin

This is the authoring guide for **native Swift plugins** — SwiftUI that Onecast **compiles from
source** and renders into its command palette (distinct from the JavaScript Raycast extensions in this
same folder). You ship a `manifest.json` and `.swift` files; the app builds and signs them itself. A
plugin runs **in-process, unsandboxed, with the app's full privileges**, so only ship code you trust.

Worked examples in this repo:

- [`stock-quotes`](stock-quotes/) — the full pattern: a **surface-only** plugin
  (`rootSurface`) with a search field, a keyboard-navigable watchlist, a ⌘K command palette and a
  pushed detail view. Copy this for anything non-trivial.
- [`hello`](hello/) — the **row model**: a run action, a drill-in child list, a small
  SwiftUI surface and an external link.

Plugins compile against `OnecastPluginKit`, the contract the host app owns and embeds; the app's
end-to-end develop/build/install reference is `docs/plugins_and_extensions.md` in the Onecast repo.
Everything you need to *write* a plugin is below.

---

## Two shapes: rows vs. a surface

A plugin is either a **row list** or a **single SwiftUI surface**. Pick one.

| | Row model | Surface-only |
|---|---|---|
| Implement | `results(for:)` (+ `perform`/`children`/`surface`) | `rootSurface(context:)` |
| Host draws | the row list, its search field, footer and keyboard nav | nothing — you own the whole panel |
| Use when | a few actions / a simple filtered list | a real app UI: search, lists, detail, charts |

A surface-only plugin returns a view from `rootSurface` and opens straight into it — there is no root
row list. Wrap that view in a **`PluginScaffold`** (below) and you get Escape-to-back, a ⌘K palette
and focus-independent list navigation for free.

## The contract

```swift
@MainActor public protocol OnecastPlugin: AnyObject {
    init()
    static var metadata: PluginMetadata { get }                                           // name/subtitle/icon
    func rootSurface(context: PluginContext) -> AnyView?                                   // default: nil
    func results(for context: PluginContext) -> [PluginResult]                            // default: []
    func children(of resultID: String, context: PluginContext) async -> [PluginResult]    // default: []
    func perform(resultID: String, context: PluginContext) async -> PluginActionResult    // default: .close
    func surface(for resultID: String, context: PluginContext) -> AnyView                 // default: EmptyView
    func bind(reload: @escaping () -> Void)                                                // default: no-op
}
```

- `PluginContext` — `query` (the live palette text), `frontmostAppBundleID`, `finderSelection`.
- `PluginIcon` — `.symbol(String)` (SF Symbol) or `.file(URL)`.
- `bind(reload:)` — the host hands you a closure; call it whenever your rows would now differ (async
  data landed, a favourite toggled) and the host re-asks `results(for:)`.
- Every call runs on the **main actor**; push heavy/IO work onto a `Task.detached` you `await`.

Minimum surface-only plugin:

```swift
import AppKit
import SwiftUI
import OnecastPluginKit

final class MyPlugin: NSObject, OnecastPlugin {
    static let metadata = PluginMetadata(name: "My Plugin", subtitle: "…", icon: "star")
    private let store = Store()

    override init() { super.init() }   // NSObject's init() alone doesn't satisfy the requirement

    func rootSurface(context: PluginContext) -> AnyView? { AnyView(RootView(store: store)) }
}

@_cdecl("onecastPluginCreate")
public func onecastPluginCreate() -> UnsafeMutableRawPointer {
    OnecastPluginRuntime.export { MyPlugin() }   // the host's only entry point — export exactly this
}
```

## PluginScaffold — the surface frame

Wrap a surface's body in `PluginScaffold`. It draws the footer, owns the surface's keyboard, and gives
you a view stack and a ⌘K palette. It claims Escape, ⌘K and the list keys through a local event
monitor that runs **ahead of the host and ahead of the search field**, so navigation never depends on
which control holds focus.

```swift
PluginScaffold(
    navigator: navigator,                 // PluginNavigator — the view stack
    primaryActionLabel: "Open",           // what Return does on *this* view, shown in the footer ("" hides it)
    commands: currentCommands,            // () -> [PluginCommand] for the ⌘K palette (re-read when it opens)
    commandTitle: { currentSymbol },      // () -> String? heading shown atop the ⌘K palette
    listKey: handleListKey,               // (PluginListKey) -> Bool  — ↑/↓/←/→/Return for your list
    escape: handleEscape,                 // () -> Bool  — Escape, before the stack pops or the plugin exits
    footer: .standard                     // .standard | .hidden | .custom { AnyView(…) }
) {
    rootView                              // your content
}
```

`primaryActionLabel` is read on every render, so make it describe the view that is actually on top —
`navigator.canPop ? "" : "Open"` when Return only opens a row on the root list. A footer chip whose
key does nothing is worse than no chip.

A bare **backspace** reaches your search field rather than backing out of the plugin: the host leaves
that key to a surface, since only the surface knows whether its field still holds text.

Verify a surface the way the app is actually used — drive the real keyboard, capture the panel and
read the pixels. The procedure, the key-code table and the register of UI bugs that slipped through
before live in the app repo's `UI_TESTS.md`.

### The footer is the shared `ActionBar`

`.standard` draws the same `ActionBar` the launcher and JS extensions use — a leading control
(a Back capsule while `navigator.canPop`, otherwise nothing), a primary-action capsule from
`primaryActionLabel`, and the Actions ⌘K toggle. You get the host's exact look, transparency and
keycaps for free, so don't rebuild a footer by hand.

Override it when a surface needs something else:

- `.hidden` — a full-bleed surface with no bar.
- `.custom { AnyView(bar) }` — your own bar. Prefer building it from the shared `ActionBar` with your
  own `ActionBarModel` so it still matches the host:

```swift
footer: .custom {
    AnyView(ActionBar(ActionBarModel(
        primary: ActionBarItem(title: "Refresh", keys: ["⌘", "R"]) { reload() })))
}
```

### PluginNavigator — Escape is back

```swift
@State private var navigator = PluginNavigator()
// ...
navigator.push(title: "AAPL") { DetailView(symbol: "AAPL") }   // drill in
navigator.pop()                                                // or let Escape do it
navigator.canPop                                               // a pushed view is on top
```

- **Escape** pops the stack; at the root it leaves the plugin. You never wire a back button or call
  the exit yourself — the scaffold and host handle it. (Never install your own Escape monitor.)
- Keep `navigator` as `@State` on your surface and pass the same instance to the scaffold.
- `escape:` runs **before** the pop and before the exit, so a surface with its own state unwinds one
  step at a time instead of dropping the whole plugin on the first press. Return false and the
  scaffold carries on as usual:

```swift
private func handleEscape() -> Bool {
    guard !navigator.canPop, !query.isEmpty else { return false }  // a pushed view pops as usual
    query = ""                                                     // clear the search first
    return true
}
```

### PluginCommand — the ⌘K palette

`commands` returns the actions for whatever view is on top; the palette (bottom-right, opened with ⌘K)
lists them with ↑/↓/Return, headed by `commandTitle()`. Typing filters the rows by a case-insensitive
match on their `title`/`subtitle` — you get the search field for free, so keep titles descriptive.

```swift
PluginCommand(
    title: "Add to Favourites",
    subtitle: nil,
    icon: .symbol("star"),
    shortcut: "⌘F",            // display hint only; each character renders as a keycap
    action: { store.toggleFavourite(symbol) })
```

### PluginListKey — focus-independent list navigation

Your list's keys arrive through `listKey`, driven by the scaffold's monitor, so they work whether the
search field, a row, or nothing holds focus. Return `true` when you consumed the key; return `false`
to let it fall through (e.g. leave ←/→ to the search caret while typing).

```swift
enum PluginListKey { case up, down, left, right, submit }
```

Single vertical list:

```swift
func handleListKey(_ key: PluginListKey) -> Bool {
    guard !items.isEmpty else { return false }
    switch key {
    case .down:   selection = min(selection + 1, items.count - 1)
    case .up:     selection = max(selection - 1, 0)
    case .submit: open(items[selection])
    case .left, .right: return false          // let the search caret have them
    }
    return true
}
```

Two axes (a horizontal row above a vertical list — see stock-quotes): ←/→ walk the row, ↓ drops into
the list, ↑ from the first list row climbs back to the remembered column. Model the selection as one
flat index and branch on which zone it's in.

## Layout: fill to the bottom, dissolve into the footer

The scaffold overlays its footer and masks a soft fade at the bottom, so your content should fill the
whole height and let its last rows dissolve under the footer. Give each scroll view a bottom content
margin so the last row can still be scrolled clear of the footer:

```swift
ScrollView { … }
    .contentMargins(.bottom, 52, for: .scrollContent)
```

## Gotchas learned the hard way

- **Focus a search field a runloop hop after appear.** Setting `@FocusState` on bare `.task`/`.onAppear`
  lands before the field is in the responder chain and silently no-ops, so typing goes nowhere. Do:
  ```swift
  .task { try? await Task.sleep(nanoseconds: 120_000_000); searchFocused = true }
  ```
- **Selection state lives on the view, as `@State`.** The scaffold's monitor calls your `listKey` /
  `commands` with the current state; don't stash selection in the plugin object.
- **Lay out a horizontally-navigated row eagerly (plain `HStack`), not `LazyVGrid`.** A lazy grid
  reuses cells and the selection ring lags a keystroke behind. Reserve fixed slots for a spinner /
  clear button in a search bar and pin its height, or it reflows and flickers as they come and go.
- **Scroll the selection into view** with a `ScrollViewReader` + `.onChange(of: selection)`; a
  horizontally-scrolling row needs its **own** reader.
- **One framework, one contract.** The app compiles every plugin against its own embedded
  `OnecastPluginKit`, so a cast across the `dlopen` boundary always resolves the same module identity —
  you never point a build at a framework yourself.

## Build & install

There is no build step. Drop a folder holding `manifest.json` and your `.swift` sources into

    ~/Library/Application Support/<bundle id>/plugins/<name>/

and Onecast compiles it for you — one `swiftc` invocation against its own embedded `OnecastPluginKit`,
ad-hoc signed, cached on a source fingerprint so an unchanged plugin never rebuilds. The dev app's
bundle id is `com.onecast.app.dev`. Enable **Settings → Plugins**, then search the plugin by name.

The simplest layout is a single `.swift` file beside the manifest. Every `.swift` under the folder is
compiled as one module, so you can split into more files (or a `Sources/` tree) as a plugin grows; a
`build`/`.build` subfolder is ignored.

```
hello/
  manifest.json
  HelloPlugin.swift
```

```json
{ "name": "My Plugin", "identifier": "com.example.my", "icon": "star" }
```

- `name`, `identifier` — required. `subtitle`, `icon` (an SF Symbol) — optional.
- `module` — optional Swift `-module-name`; derived from `name` when omitted (`Stock Quotes` →
  `StockQuotes`). The `@_cdecl("onecastPluginCreate")` entry point is module-independent, so the name
  only matters if two plugins would otherwise collide.

**Requirements.** Building needs a Swift toolchain — Xcode or the Command Line Tools
(`xcode-select --install`). A missing toolchain, or a compile error, surfaces in the palette where the
plugin would run, carrying the compiler diagnostic.

**Editing is live.** A plugin dropped in — or a source file edited — while Onecast runs is picked up
within a moment (the folder is watched) and rebuilt in the background. Reopening the plugin maps the
fresh build; the running session keeps its current image until you leave it, and no app relaunch is
needed.
