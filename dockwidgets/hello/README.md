# Hello — a sample Onecast DockWidget

A worked example of a **DockWidget**: a live tile in one of Onecast's custom docks, written in
SwiftUI and compiled from source by the app. It shows:

- **two sizes** — a compact tile (just the glyph) and a wide one (glyph, greeting and a counter),
  stacking instead of running sideways on a left/right dock;
- **a preference** — `greeting`, edited per tile in the dock editor and read live in `tile(context:)`;
- **a popover** — a click opens a counter with buttons that use the host actions (`openURL`,
  `closePopover`, `openSettings`);
- **per-instance state** — the wave counter lives in the widget object, so two Hello tiles count
  separately.

The full guide is `custom_docs/dockwidgets.md` in the Onecast repo.

## Install

There is no build step — Onecast compiles the widget from source. Run **Reload DockWidgets** in
Onecast and pick Hello (or All DockWidgets), or copy it by hand:

```sh
DEST="$HOME/Library/Application Support/com.onecast.app.dev/dockwidgets/hello"
mkdir -p "$DEST" && cp manifest.json HelloWidget.swift "$DEST/"
```

Then, in Onecast: **Settings → Docks**, turn Docks on, allow third-party DockWidgets, and add
**Hello** from the widget library to a dock (pick Compact or Wide). Building needs a Swift toolchain
(Xcode or the Command Line Tools); a compile error shows in Settings → Docks beside the widget and
as a warning tile on the dock.

## Layout

```
hello/
  manifest.json       name, identifier, subtitle, icon, category, sizes, module, preferences
  HelloWidget.swift   the whole widget, beside the manifest
```
