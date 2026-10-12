# OneCast Addons

Extensions and native Swift plugins for **[OneCast](https://github.com/jhasubhash/onecast)** — the
native macOS launcher. This is where my own add-ons live, kept out of the app repo so they cost zero
rebase surface and survive every upstream release untouched.

## Layout

| Folder | Holds |
| --- | --- |
| `extensions/` | Raycast-compatible JS/TS extensions, one per folder, each with its own `package.json` and esbuild step. |
| `plugins/` | Native SwiftUI plugins Onecast compiles from source against `OnecastPluginKit`. |
| `dockwidgets/` | DockWidgets — live SwiftUI tiles for Onecast's custom docks, compiled from source against `OnecastPluginKit`. |

**Extensions:** `copy-path`, `fork-rsync-status`, `gh-account-switcher`, `github-pr-monitor`, `jira`,
`kill-process`, `news-search`, `parse-text`, `reload-extensions`, `reload-plugins`,
`reload-dockwidgets`, `slack-status`.

**Plugins:** `hello`, `stock-quotes`.

**DockWidgets:** `hello`, `leetcode`.

See [`extensions/GOTCHAS.md`](extensions/GOTCHAS.md) for how OneCast's `@raycast/api` runtime differs
from real Raycast, and [`plugins/SWIFT_PLUGINS.md`](plugins/SWIFT_PLUGINS.md) for authoring a native
plugin.

## Build & install

**Extensions** — restore dependencies and bundle each command:

```sh
cd extensions/<name>
npm ci
npm run build          # esbuild writes <command>.js beside the manifest
```

Then install from the app: **OneCast → Settings → Extensions → Add**, and point the folder picker at
the built extension(s). OneCast copies the manifest, the built `<command>.js` and `assets/` into
`~/Library/Application Support/<bundle id>/extensions/`.

**Plugins** — there is no build step. Copy the manifest and sources into Onecast's plugins folder:

```sh
cd plugins/<name>
DEST="$HOME/Library/Application Support/com.onecast.app.dev/plugins/<name>"
mkdir -p "$DEST" && cp manifest.json *.swift "$DEST/"
```

Onecast compiles the sources against its own embedded framework, ad-hoc signs the dylib, and caches
it — enable **Settings → Plugins**, then search the plugin by name. Editing a source and reopening the
plugin rebuilds it with no app relaunch. Building needs a Swift toolchain (Xcode or the Command Line
Tools).

**DockWidgets** — the same, into the dockwidgets folder (the authoring guide is
`custom_docs/dockwidgets.md` in the Onecast repo):

```sh
cd dockwidgets/<name>
DEST="$HOME/Library/Application Support/com.onecast.app.dev/dockwidgets/<name>"
mkdir -p "$DEST" && cp manifest.json *.swift "$DEST/"
```

Enable **Settings → Docks**, allow third-party DockWidgets, then add the widget to a dock. Editing the
installed copy rebuilds it and refreshes the live tiles; to push edits from this repo instead, run
**Reload DockWidgets** (the `reload-dockwidgets` extension) — it copies one widget or all of them
from `dockwidgets/` into the running channel's folder, which triggers the same rebuild.

`node_modules/` and the built `<command>.js` are gitignored — restore them with `npm ci && npm run
build`. Plugins have no build artifacts to ignore: Onecast compiles them into its own caches.


