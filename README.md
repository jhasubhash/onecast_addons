<div align="center">

# OneCast Addons

**Extensions, native Swift plugins and DockWidgets for [OneCast](https://github.com/jhasubhash/onecast).**

My own add-ons for the native macOS launcher. They live outside the app repo, so they never get in
the way of an upstream rebase and survive every release untouched.

[![OneCast](https://img.shields.io/github/v/release/jhasubhash/onecast?sort=semver&label=OneCast&color=1F6FEB)](https://github.com/jhasubhash/onecast/releases/latest)
![macOS 26+](https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![TypeScript](https://img.shields.io/badge/TypeScript-Raycast%20API-3178C6?logo=typescript&logoColor=white)

<a href="https://www.buymeacoffee.com/subhashjha"><img src="https://img.buymeacoffee.com/button-api/?text=Buy%20me%20a%20coffee&emoji=&slug=subhashjha&button_colour=FFDD00&font_colour=000000&font_family=Cookie&outline_colour=000000&coffee_colour=ffffff" alt="Buy me a coffee" height="44"></a>

</div>

| | Kind | What it is |
|---|---|---|
| 🧩 | **[Extensions](#-extensions)** | Raycast-compatible TypeScript extensions, run by OneCast's `@raycast/api` runtime. |
| 🦅 | **[Plugins](#-plugins)** | Native SwiftUI plugins OneCast compiles from source against `OnecastPluginKit`. |
| 🧱 | **[DockWidgets](#-dockwidgets)** | Live SwiftUI tiles for OneCast's custom docks, compiled the same way. |
| 🔗 | **[Quicklinks](#-quicklinks)** | Importable quicklink files. |

---

## 🧩 Extensions

<table>
<tr>
<td width="50%" valign="top">
<img src="docs/screenshots/extension-kill-process.png" alt="Kill Process">
<p><b>Kill Process</b>: everything running, apps, helpers and daemons, sorted by the memory or CPU it costs.
Quit or force-kill it, and see plainly when a process belongs to root.</p>
</td>
<td width="50%" valign="top">
<img src="docs/screenshots/extension-news-search.png" alt="News Search">
<p><b>News Search</b>: top articles from Google News, with the source and age of each one.</p>
</td>
</tr>
<tr>
<td valign="top">
<img src="docs/screenshots/extension-gh-account-switcher.png" alt="GitHub Account Switcher">
<p><b>GitHub Account Switcher</b>: switch the active <code>gh</code> account on github.com or GHES,
or toggle between two with no view at all.</p>
</td>
<td valign="top">
<img src="docs/screenshots/extension-reload-extensions.png" alt="Reload Extensions">
<p><b>Reload Extensions</b>: rebuild an extension from its source folder and install it into the
running app, one at a time or all of them.</p>
</td>
</tr>
<tr>
<td valign="top">
<img src="docs/screenshots/extension-reload-plugins.png" alt="Reload Plugins">
<p><b>Reload Plugins</b>: rebuild native Swift plugins from source and restart OneCast so the new
code loads.</p>
</td>
<td valign="top">
<img src="docs/screenshots/extension-reload-dockwidgets.png" alt="Reload DockWidgets">
<p><b>Reload DockWidgets</b>: copy widgets from <code>dockwidgets/</code> into OneCast, which
recompiles them and swaps every live tile onto the new build.</p>
</td>
</tr>
</table>

And a few more that need an account or run without a view:

| Extension | What it does |
|---|---|
| **Copy Path** | Copies what the frontmost app points at: Finder's selection as paths, a browser's page URL. |
| **Parse Text** | Cleans up the selected text (or the clipboard), starting with links a line-wrap split in two. |
| **Fork Sync Status** | Checks whether your fork is in sync with its upstream, using the `gh` CLI. |
| **GitHub PR Monitor** | Your open PRs and review requests, using the `gh` CLI. |
| **Jira** | Browse and search your issues with a Personal Access Token. |
| **Slack Status** | Set or clear your status with presets, emoji and an expiry, and swap your profile photo. |

## 🦅 Plugins

<table>
<tr>
<td width="33%" valign="top">
<img src="docs/screenshots/plugin-stock-quotes.png" alt="Stock Quotes">
<p><b>Stock Quotes</b>: live prices, charts, favourites and a watchlist.</p>
</td>
<td width="33%" valign="top">
<img src="docs/screenshots/plugin-snake.png" alt="Snake">
<p><b>Snake</b>: retro snake, right in the palette.</p>
</td>
<td width="33%" valign="top">
<img src="docs/screenshots/plugin-hello.png" alt="Hello">
<p><b>Hello</b>: a sample plugin showing the HUD, a live surface and drill-down lists.</p>
</td>
</tr>
</table>

## 🧱 DockWidgets

<table>
<tr>
<td width="140" valign="top"><img src="docs/screenshots/dockwidget-leetcode.png" alt="LeetCode DockWidget" width="120"></td>
<td valign="top">

**LeetCode**: a problem a day, with streaks, XP, freezes and badges. It picks a problem by your
difficulty and topics (or takes the daily challenge), marks the day done once your solution is
accepted, and reminds you through OneCast's scheduler until it is.

**Hello**: a sample widget in compact and wide sizes, with one preference.

</td>
</tr>
</table>

## 🔗 Quicklinks

`quicklinks/` holds **Search Google** and **Open in Finder**, ready to import from
**OneCast → Settings → Quicklinks**.

---

## Build & install

**Extensions** need a build step: restore the dependencies and bundle each command.

```sh
cd extensions/<name>
npm ci
npm run build          # esbuild writes <command>.js beside the manifest
```

Then add it in **OneCast → Settings → Extensions → Add** and pick the built folder. OneCast copies
the manifest, the built `<command>.js` files and `assets/` into
`~/Library/Application Support/<bundle id>/extensions/`. Each extension's `install.sh` does the same
from the command line.

**Plugins** have no build step: copy the manifest and sources into OneCast's plugins folder.

```sh
cd plugins/<name>
DEST="$HOME/Library/Application Support/com.onecast.app.dev/plugins/<name>"
mkdir -p "$DEST" && cp manifest.json *.swift "$DEST/"
```

OneCast compiles the sources against its own embedded framework, signs the dylib and caches it.
Turn on **Settings → Plugins**, then search for the plugin by name. Editing a source and reopening
the plugin rebuilds it with no relaunch. Building needs Xcode or the Command Line Tools.

**DockWidgets** work the same way, into the `dockwidgets` folder:

```sh
cd dockwidgets/<name>
DEST="$HOME/Library/Application Support/com.onecast.app.dev/dockwidgets/<name>"
mkdir -p "$DEST" && cp manifest.json *.swift "$DEST/"
```

Turn on **Settings → Docks**, allow third-party DockWidgets, and add the widget to a dock. To push
edits from this repo, run **Reload DockWidgets**.

> [!TIP]
> Swap `com.onecast.app.dev` for `com.onecast.app` to install into the release app instead of a
> dev build.

## Learn more

- **[`extensions/GOTCHAS.md`](extensions/GOTCHAS.md)**: where OneCast's `@raycast/api` runtime
  differs from Raycast's.
- **[`plugins/SWIFT_PLUGINS.md`](plugins/SWIFT_PLUGINS.md)**: writing a native plugin.
- **`custom_docs/dockwidgets.md`** in the OneCast repo: writing a DockWidget.

`node_modules/` and the built `<command>.js` files are gitignored; `npm ci && npm run build` brings
them back. Plugins and DockWidgets leave nothing to ignore, since OneCast compiles them into its own
caches.

## Support

If these make your Mac a nicer place to be, you can
[buy me a coffee](https://www.buymeacoffee.com/subhashjha) ☕
