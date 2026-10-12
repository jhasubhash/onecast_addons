# Reload Onecast Extensions

Rebuild an extension from its source folder and install it into the running Onecast, without a
terminal. This is the in-app equivalent of `npm run ship`.

Originally a Raycast extension that drove `ray develop`; rewritten for Onecast, which has no `ray`
CLI and no dev server — an extension is just a manifest plus one prebuilt CommonJS file per command,
so "reload" is build and copy; Onecast notices the new install on its own.

## What a reload does

1. `npm install` when `node_modules/` is missing.
2. `npm run build` — the extension's own esbuild line.
3. Copies exactly what `ExtensionCatalog.install` copies into
   `<appSupport>/<bundleId>/extensions/<name>/`: `package.json`, one `<command>.js` per declared
   command, and `assets/`. Never `node_modules`, never a `.js.map`.

The install root is derived from `environment.supportPath`, which Onecast keys by bundle id, so a
reload run from `Onecast Dev.app` installs into the dev channel and one run from a release build
installs into that. Nothing is hardcoded.

## When Onecast notices

Onecast reads a command's `.js` from disk every time it launches, so **a code change needs nothing
else** — run the command again and the new build is what executes.

The installed *set* — which commands the launcher lists — is derived from manifests, and Onecast
watches its extensions folder: a reload swaps the extension's directory in, and that swap alone
makes `ExtensionManager.refresh()` re-scan. Added, renamed and removed commands show up without
opening Settings or relaunching.

## Preferences

**Extensions Folder** — the directory holding one source extension per subdirectory. Defaults to
`~/Developer/onecast_addons/extensions`. A subdirectory counts when it has a `package.json` with a
non-empty `commands[]`.

## npm resolution

A GUI app inherits a bare `PATH`. Onecast appends `/opt/homebrew/bin` and friends when it boots an
extension, so Homebrew's `npm` resolves directly and the common case costs nothing. If `npm` is not
there — a node managed only by nvm, say — the command asks the login shell once
(`$SHELL -lic 'command -v npm'`), caches the answer, and prepends its directory to `PATH` so npm's
`env node` shebang resolves too. That shell costs seconds, which is why it is a fallback and not the
default path.

A spawn must be given `env: process.env` explicitly. The runtime resolves the executable against an
augmented `PATH` but hands the child the app's own environment, so a bare `npm` is *found* and then
dies with `env: node: No such file or directory` — exit 127, not `ENOENT`. Measured both ways with a
probe extension under a launchd-like `PATH`.

## No `fs.cpSync`

Onecast's Node shim has `existsSync`, `readFileSync`, `readdirSync` (including `withFileTypes`),
`statSync`, `rmSync`, `mkdirSync` and `copyFileSync` — but **not `cpSync`**. Copying `assets/` with
it failed every single rebuild with `fs.cpSync is not a function`, and because every extension here
ships an `assets/` directory, that read as "0 rebuilt · 13 failed" with no clue why. `copyTree()`
walks the tree with the calls the shim does have.

The lesson generalises: a Node API that exists in your terminal may not exist in the runtime. Verify
against the engine — `ext-test` with a throwaway probe extension — not against `node` on the command
line, which has the full standard library and will happily hide the gap.
