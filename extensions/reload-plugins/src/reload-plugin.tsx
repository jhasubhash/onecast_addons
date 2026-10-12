import {
  Action,
  ActionPanel,
  Color,
  Icon,
  List,
  Toast,
  environment,
  getPreferenceValues,
  showToast,
} from "@raycast/api";
import * as fs from "node:fs";
import { homedir } from "node:os";
import * as path from "node:path";
import { useMemo, useState } from "react";

interface Prefs {
  pluginsRoot?: string;
}

interface Plugin {
  name: string;
  dir: string;
}

/** Onecast compiles native plugins from source now, so a plugin folder is just a manifest.json with at
 *  least one .swift beside it — the old build.sh + Sources/ layout is gone. Mirrors PluginCatalog.scan. */
function hasSwiftSource(dir: string): boolean {
  const walk = (d: string): boolean => {
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(d, { withFileTypes: true });
    } catch {
      return false;
    }
    for (const e of entries) {
      if (e.name.startsWith(".") || e.name === "build") continue;
      if (e.isDirectory()) {
        if (walk(path.join(d, e.name))) return true;
      } else if (e.name.endsWith(".swift")) {
        return true;
      }
    }
    return false;
  };
  return walk(dir);
}

function discoverPlugins(root: string): Plugin[] {
  if (!fs.existsSync(root)) return [];
  return fs
    .readdirSync(root, { withFileTypes: true })
    .filter(
      (e) =>
        e.isDirectory() &&
        fs.existsSync(path.join(root, e.name, "manifest.json")) &&
        hasSwiftSource(path.join(root, e.name)),
    )
    .flatMap((e) => {
      const dir = path.join(root, e.name);
      try {
        const m = JSON.parse(fs.readFileSync(path.join(dir, "manifest.json"), "utf8"));
        return [{ name: String(m.name || e.name), dir }];
      } catch {
        return [];
      }
    })
    .sort((a, b) => a.name.localeCompare(b.name));
}

/** Try the configured root, then the default, then any `…/extensions` → `…/plugins` sibling, and pick
 *  the first that actually holds plugins. Falls back to the first candidate for the empty-state text. */
function resolvePluginsRoot(pref?: string): { root: string; plugins: Plugin[] } {
  const candidates: string[] = [];
  const push = (p: string) => {
    if (p && !candidates.includes(p)) candidates.push(p);
  };
  const configured = pref?.trim();
  if (configured) push(configured.startsWith("~") ? path.join(homedir(), configured.slice(1)) : configured);
  push(path.join(homedir(), "Developer/onecast_addons/plugins"));
  for (const c of [...candidates]) {
    if (c.endsWith(`${path.sep}extensions`)) push(`${c.slice(0, -"extensions".length)}plugins`);
  }
  for (const c of candidates) {
    const found = discoverPlugins(c);
    if (found.length) return { root: c, plugins: found };
  }
  return { root: candidates[0], plugins: [] };
}

/** The running channel's plugins folder — `…/<bundleId>/plugins`, the very directory the app's
 *  PluginCatalog scans — derived from this command's support path, so Dev and release differ. */
function installedPluginsDir(): string {
  return path.join(path.resolve(environment.supportPath, "..", ".."), "plugins");
}

/** Recursive copy (the runtime has no cpSync): manifest.json + .swift and anything else, minus
 *  compiler output and dotfiles. */
function copyTree(src: string, dest: string): void {
  fs.mkdirSync(dest, { recursive: true });
  for (const e of fs.readdirSync(src, { withFileTypes: true })) {
    if (e.name.startsWith(".") || e.name === "build" || e.name === ".build") continue;
    const from = path.join(src, e.name);
    const to = path.join(dest, e.name);
    if (e.isDirectory()) copyTree(from, to);
    else if (e.isFile()) fs.copyFileSync(from, to);
  }
}

/** Reload = copy the plugin's source into the app's plugins folder; the app's watcher recompiles and
 *  the next open loads the fresh module — no author build step, no dylib. */
function installPlugin(plugin: Plugin, pluginsDir: string): void {
  const dest = path.join(pluginsDir, path.basename(plugin.dir));
  fs.rmSync(dest, { recursive: true, force: true });
  copyTree(plugin.dir, dest);
}

type Stat = { state: "reloading" | "ok" | "fail"; note?: string };

export default function Command() {
  const prefs = getPreferenceValues<Prefs>();
  const { root, plugins } = useMemo(() => resolvePluginsRoot(prefs.pluginsRoot), [prefs.pluginsRoot]);
  const pluginsDir = useMemo(() => installedPluginsDir(), []);

  const [status, setStatus] = useState<Record<string, Stat>>({});
  const busy = Object.values(status).some((s) => s.state === "reloading");
  const set = (name: string, s: Stat) => setStatus((prev) => ({ ...prev, [name]: s }));

  function reload(plugin: Plugin): boolean {
    set(plugin.name, { state: "reloading" });
    try {
      installPlugin(plugin, pluginsDir);
      set(plugin.name, { state: "ok", note: "installed · reopen to load" });
      return true;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      set(plugin.name, { state: "fail", note: msg.trim().slice(0, 300) });
      return false;
    }
  }

  async function reloadOne(plugin: Plugin) {
    if (reload(plugin)) {
      await showToast({
        style: Toast.Style.Success,
        title: `Reloaded ${plugin.name}`,
        message: "Reopen the plugin to load the new build",
      });
    }
  }

  async function reloadAll() {
    let ok = 0;
    for (const p of plugins) if (reload(p)) ok++;
    await showToast({
      style: ok === plugins.length ? Toast.Style.Success : Toast.Style.Failure,
      title: `Reloaded ${ok}/${plugins.length}`,
      message:
        ok === plugins.length
          ? "Reopen a plugin to load its new build"
          : "Some copies failed — see the row for details",
    });
  }

  const accessoryFor = (name: string): List.Item.Accessory[] => {
    const s = status[name];
    if (!s) return [];
    if (s.state === "reloading") return [{ tag: { value: "Reloading…", color: Color.Yellow } }];
    if (s.state === "ok") return [{ tag: { value: s.note ?? "reloaded", color: Color.Green } }];
    return [{ tag: { value: "failed", color: Color.Red }, tooltip: s.note }];
  };

  const channel = path.basename(path.dirname(pluginsDir));

  return (
    <List isLoading={busy} navigationTitle="Reload Plugins" searchBarPlaceholder="Filter native plugins…">
      <List.EmptyView
        icon={Icon.Plug}
        title="No native plugins found"
        description={`Nothing with a manifest.json + a .swift under ${root}. Set the folder in this command's preferences.`}
      />
      <List.Item
        title="All Plugins"
        subtitle={`${plugins.length} · ${channel}`}
        icon={{ source: Icon.ArrowClockwise, tintColor: Color.Blue }}
        actions={
          <ActionPanel>
            <Action title="Reload All" icon={Icon.ArrowClockwise} onAction={() => void reloadAll()} />
          </ActionPanel>
        }
      />
      {plugins.map((p) => (
        <List.Item
          key={p.name}
          title={p.name}
          subtitle={p.dir}
          icon={{ source: Icon.Plug, tintColor: Color.Purple }}
          accessories={accessoryFor(p.name)}
          actions={
            <ActionPanel>
              <Action title="Reload" icon={Icon.Hammer} onAction={() => void reloadOne(p)} />
              <Action
                title="Reload All"
                icon={Icon.ArrowClockwise}
                shortcut={{ modifiers: ["cmd"], key: "b" }}
                onAction={() => void reloadAll()}
              />
              <Action.ShowInFinder
                title="Open Source Folder"
                path={p.dir}
                shortcut={{ modifiers: ["cmd"], key: "o" }}
              />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
