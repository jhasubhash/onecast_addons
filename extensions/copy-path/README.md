# Copy Path

Copies whatever the frontmost app is pointing at, choosing the answer by app:

| Frontmost app | Copies |
| --- | --- |
| Finder | the POSIX paths of the selected files and folders; with nothing selected, the folder the window is showing |
| Safari, Safari Technology Preview, Orion | the front document's URL |
| Chrome, Brave, Edge, Arc, Dia, Vivaldi, Opera, Chromium, Comet | the active tab's URL |
| OnePaper | the open page's path from the top of its folders, `Health/Temp/Blood Sugar & BP Tracker` (or its `onepaper://doc/…` link, by preference), from the `AXDocument` OnePaper sets |
| anything else | the front window's `AXDocument` — a `file://` URL becomes a path, a page address stays a URL; if that is unset, the `AXURL` of the focused window's web area (Crest and other browsers with broken AppleScript) |

`mode: "no-view"`, so it copies and shows a HUD without opening a palette screen. An app with no
answer — no open window, or one that exposes no document — reports that in a failure toast.

## Build and install

```sh
npm install
npm run ship         # build, then copy into Onecast Dev's extensions directory
```

`./install.sh com.onecast.app` installs into the released app instead. See
[`../fork-sync/README.md`](../fork-sync/README.md) for the shared build loop and the `ext-test`
harness — every extension here is built the same way.

## Preferences

- **Multiple Items** — how several selected paths are joined: one per line, space, or comma.
- **OnePaper** — copy the page's path (the default) or its `onepaper://doc/<id>` link, which reopens the page.
- **Quote paths containing spaces** — wraps such a path in `"`, so a multi-file copy pastes into a
  shell as separate arguments.

## Permissions

The Finder branch and the browser branches send Apple events; the fallback branch drives System
Events, which needs Accessibility. macOS prompts **for Onecast**, once per target app, the first
time a branch runs. Deny one and that branch reports a failure toast until it is granted in
**System Settings → Privacy & Security → Automation / Accessibility**.

## How the branches are chosen

`getFrontmostApplication()` is a Onecast host call that reports the app the palette displaced, not
the palette itself, so the bundle id it returns is the one to dispatch on.

Finder uses `getSelectedFinderItems()` — a host API, so the Apple event is sent by Onecast in
process rather than by a spawned `osascript`. Everything else shells out to `osascript` through
`node:child_process`.

Two AppleScript details that are easy to get wrong, both found by testing against running apps:

- **Chromium and WebKit spell the address bar differently.** Chromium answers
  `URL of active tab of front window`, WebKit answers `URL of front document`. `BROWSER_DIALECT`
  maps each bundle id to one of the two; adding a browser is one line there. Addressing by
  `application id` rather than by name means a renamed or localised app still resolves.
- **The System Events fallback must bind the process to a variable first.** Inlining the filter —
  `tell (first process whose bundle identifier is …)` — resolves to `process 1` and fails with
  `Can't get window 1 of process 1`. `set proc to first process whose …` then
  `window 1 of proc` works.
