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
  widgetsRoot?: string;
}

interface Widget {
  name: string;
  identifier: string;
  dir: string;
}

/** A DockWidget folder is a manifest.json with at least one .swift under it. Mirrors DockWidgetCatalog.scan. */
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

function discoverWidgets(root: string): Widget[] {
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
        return [{ name: String(m.name || e.name), identifier: String(m.identifier || ""), dir }];
      } catch {
        return [];
      }
    })
    .sort((a, b) => a.name.localeCompare(b.name));
}

/** Try the configured root, then the default, and pick the first that actually holds widgets. */
function resolveWidgetsRoot(pref?: string): { root: string; widgets: Widget[] } {
  const candidates: string[] = [];
  const push = (p: string) => {
    if (p && !candidates.includes(p)) candidates.push(p);
  };
  const configured = pref?.trim();
  if (configured) push(configured.startsWith("~") ? path.join(homedir(), configured.slice(1)) : configured);
  push(path.join(homedir(), "Developer/onecast_addons/dockwidgets"));
  for (const c of candidates) {
    const found = discoverWidgets(c);
    if (found.length) return { root: c, widgets: found };
  }
  return { root: candidates[0], widgets: [] };
}

/** Recursive copy minus compiler output and dotfiles (the runtime has no cpSync). */
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

/** Reload = replace the installed copy with the source; Onecast's folder watcher recompiles it and
 *  swaps every live tile of that widget onto the new build. */
function installWidget(widget: Widget, widgetsDir: string): void {
  const dest = path.join(widgetsDir, path.basename(widget.dir));
  fs.rmSync(dest, { recursive: true, force: true });
  copyTree(widget.dir, dest);
}

type Stat = { state: "reloading" | "ok" | "fail"; note?: string };

export default function Command() {
  const prefs = getPreferenceValues<Prefs>();
  const { root, widgets } = useMemo(() => resolveWidgetsRoot(prefs.widgetsRoot), [prefs.widgetsRoot]);
  // `…/<bundleId>/dockwidgets`, the folder DockWidgetCatalog scans, so Dev and release differ.
  const widgetsDir = useMemo(
    () => path.join(path.resolve(environment.supportPath, "..", ".."), "dockwidgets"),
    [],
  );

  const [status, setStatus] = useState<Record<string, Stat>>({});
  const busy = Object.values(status).some((s) => s.state === "reloading");
  const set = (name: string, s: Stat) => setStatus((prev) => ({ ...prev, [name]: s }));

  function reload(widget: Widget): boolean {
    set(widget.name, { state: "reloading" });
    try {
      installWidget(widget, widgetsDir);
      set(widget.name, { state: "ok", note: "installed · rebuilding" });
      return true;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      set(widget.name, { state: "fail", note: msg.trim().slice(0, 300) });
      return false;
    }
  }

  const rebuildNote = "Onecast rebuilds it now; tiles update when the build lands";

  async function reloadOne(widget: Widget) {
    if (reload(widget)) {
      await showToast({ style: Toast.Style.Success, title: `Reloaded ${widget.name}`, message: rebuildNote });
    }
  }

  async function reloadAll() {
    let ok = 0;
    for (const w of widgets) if (reload(w)) ok++;
    await showToast({
      style: ok === widgets.length ? Toast.Style.Success : Toast.Style.Failure,
      title: `Reloaded ${ok}/${widgets.length}`,
      message: ok === widgets.length ? rebuildNote : "Some copies failed — see the row for details",
    });
  }

  const accessoryFor = (name: string): List.Item.Accessory[] => {
    const s = status[name];
    if (!s) return [];
    if (s.state === "reloading") return [{ tag: { value: "Reloading…", color: Color.Yellow } }];
    if (s.state === "ok") return [{ tag: { value: s.note ?? "reloaded", color: Color.Green } }];
    return [{ tag: { value: "failed", color: Color.Red }, tooltip: s.note }];
  };

  const channel = path.basename(path.dirname(widgetsDir));

  return (
    <List isLoading={busy} navigationTitle="Reload DockWidgets" searchBarPlaceholder="Filter DockWidgets…">
      <List.EmptyView
        icon={Icon.AppWindowGrid3x3}
        title="No DockWidgets found"
        description={`Nothing with a manifest.json + a .swift under ${root}. Set the folder in this command's preferences.`}
      />
      <List.Item
        title="All DockWidgets"
        subtitle={`${widgets.length} · ${channel}`}
        icon={{ source: Icon.ArrowClockwise, tintColor: Color.Blue }}
        actions={
          <ActionPanel>
            <Action title="Reload All" icon={Icon.ArrowClockwise} onAction={() => void reloadAll()} />
          </ActionPanel>
        }
      />
      {widgets.map((w) => (
        <List.Item
          key={w.name}
          title={w.name}
          subtitle={w.identifier || w.dir}
          icon={{ source: Icon.AppWindowGrid3x3, tintColor: Color.Purple }}
          accessories={accessoryFor(w.name)}
          actions={
            <ActionPanel>
              <Action title="Reload" icon={Icon.Hammer} onAction={() => void reloadOne(w)} />
              <Action
                title="Reload All"
                icon={Icon.ArrowClockwise}
                shortcut={{ modifiers: ["cmd"], key: "b" }}
                onAction={() => void reloadAll()}
              />
              <Action.ShowInFinder
                title="Open Source Folder"
                path={w.dir}
                shortcut={{ modifiers: ["cmd"], key: "o" }}
              />
              <Action.ShowInFinder
                title="Open Installed Folder"
                path={widgetsDir}
                shortcut={{ modifiers: ["cmd", "shift"], key: "o" }}
              />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
