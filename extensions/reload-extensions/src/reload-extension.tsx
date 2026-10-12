import {
  Action,
  ActionPanel,
  Color,
  Icon,
  Image,
  List,
  environment,
  getPreferenceValues,
} from "@raycast/api";
import { useState } from "react";
import { execFile } from "node:child_process";
import * as fs from "node:fs";
import { homedir } from "node:os";
import * as path from "node:path";
import { promisify } from "node:util";

const run = promisify(execFile);

// Onecast keys both directories by bundle id: supportPath is
// <appSupport>/<bundleId>/extension-support/<name>, so the install root is two levels up. Deriving
// it rather than hardcoding is what makes this work in the Dev channel and a release build alike.
const INSTALL_ROOT = path.resolve(
  environment.supportPath,
  "..",
  "..",
  "extensions",
);

interface Extension {
  name: string;
  dir: string;
  icon: Image.ImageLike;
  commands: number;
}

function manifestOf(dir: string): {
  name?: string;
  icon?: string;
  commands?: { name: string }[];
} {
  return JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf8"));
}

function discoverExtensions(root: string): Extension[] {
  if (!fs.existsSync(root)) return [];
  return fs
    .readdirSync(root, { withFileTypes: true })
    .filter(
      (entry) =>
        entry.isDirectory() &&
        fs.existsSync(path.join(root, entry.name, "package.json")),
    )
    .flatMap((entry) => {
      const dir = path.join(root, entry.name);
      let manifest;
      try {
        manifest = manifestOf(dir);
      } catch {
        return [];
      }
      if (!manifest.commands?.length) return [];
      const asset = manifest.icon
        ? path.join(dir, "assets", manifest.icon)
        : "";
      return [
        {
          name: entry.name,
          dir,
          icon: asset && fs.existsSync(asset) ? { source: asset } : Icon.Box,
          commands: manifest.commands.length,
        },
      ];
    })
    .sort((a, b) => a.name.localeCompare(b.name));
}

// A GUI app's PATH holds no version-manager shims, so `npm` may not resolve. Ask the login shell
// once, then reuse the answer — an interactive zsh costs seconds, and it is the only thing that
// sees an nvm-managed node.
let resolvedNpm: string | undefined;

async function npm(args: string[], cwd: string): Promise<void> {
  const options = { cwd, env: process.env, maxBuffer: 16 * 1024 * 1024 };
  try {
    await run(resolvedNpm ?? "npm", args, options);
    return;
  } catch (error) {
    if (resolvedNpm || (error as NodeJS.ErrnoException).code !== "ENOENT")
      throw error;
  }
  const shell = process.env.SHELL ?? "/bin/zsh";
  const { stdout } = await run(shell, ["-lic", "command -v npm"], {
    maxBuffer: 1024 * 1024,
  });
  const found = stdout.trim().split("\n").pop();
  if (!found)
    throw new Error("npm is not on PATH and the login shell could not find it");
  resolvedNpm = found;
  // npm's shebang runs `env node`, so its own directory has to come along.
  const env = {
    ...process.env,
    PATH: `${path.dirname(found)}:${process.env.PATH ?? ""}`,
  };
  await run(found, args, { ...options, env });
}

/// Onecast's Node shim has no `fs.cpSync`, and `assets/` nests — walk it with what the shim does
/// have. Calling cpSync here failed every rebuild with "fs.cpSync is not a function".
function copyTree(from: string, to: string): void {
  fs.mkdirSync(to, { recursive: true });
  for (const entry of fs.readdirSync(from, { withFileTypes: true })) {
    const source = path.join(from, entry.name);
    const target = path.join(to, entry.name);
    if (entry.isDirectory()) copyTree(source, target);
    else fs.copyFileSync(source, target);
  }
}

/// Build, then install exactly what ExtensionCatalog.install copies: the manifest, one bundle per
/// declared command, and assets/. Onecast watches its extensions folder, so the swap below is all
/// it takes for the launcher to pick up added, renamed or removed commands.
async function reloadExtension(ext: Extension): Promise<void> {
  if (!fs.existsSync(path.join(ext.dir, "node_modules"))) {
    await npm(["install", "--silent"], ext.dir);
  }
  await npm(["run", "build"], ext.dir);

  const manifest = manifestOf(ext.dir);
  const built = (manifest.commands ?? []).filter((command) =>
    fs.existsSync(path.join(ext.dir, `${command.name}.js`)),
  );
  if (built.length === 0)
    throw new Error("the build produced no command bundles");

  const destination = path.join(
    INSTALL_ROOT,
    (manifest.name ?? ext.name).replaceAll("/", "-"),
  );
  // Stage the whole copy, then swap. A failure part-way used to leave the installed extension
  // gutted — that is how a broken assets/ copy cost every command its icon until the next rebuild.
  // The staging name is dot-prefixed because ExtensionCatalog.scan() skips hidden entries, so a
  // leftover from a crash is never mistaken for a second installed extension.
  const staging = path.join(
    INSTALL_ROOT,
    `.${path.basename(destination)}.incoming`,
  );
  fs.rmSync(staging, { recursive: true, force: true });
  fs.mkdirSync(staging, { recursive: true });
  fs.copyFileSync(
    path.join(ext.dir, "package.json"),
    path.join(staging, "package.json"),
  );
  for (const command of built) {
    fs.copyFileSync(
      path.join(ext.dir, `${command.name}.js`),
      path.join(staging, `${command.name}.js`),
    );
  }
  const assets = path.join(ext.dir, "assets");
  if (fs.existsSync(assets)) copyTree(assets, path.join(staging, "assets"));

  fs.rmSync(destination, { recursive: true, force: true });
  fs.renameSync(staging, destination);
}

export default function Command() {
  const configured = getPreferenceValues<{
    extensionsRoot?: string;
  }>().extensionsRoot?.trim();
  const fallback = path.join(homedir(), "Developer/onecast_addons/extensions");
  const raw = configured || fallback;
  const root = raw.startsWith("~") ? path.join(homedir(), raw.slice(1)) : raw;
  const extensions = discoverExtensions(root);

  type Stat = { state: "building" | "ok" | "fail"; note?: string };
  const [status, setStatus] = useState<Record<string, Stat>>({});
  const busy = Object.values(status).some((s) => s.state === "building");
  const set = (name: string, s: Stat) =>
    setStatus((prev) => ({ ...prev, [name]: s }));

  async function handleReload(ext: Extension) {
    set(ext.name, { state: "building" });
    try {
      await reloadExtension(ext);
      set(ext.name, { state: "ok" });
    } catch (error) {
      set(ext.name, {
        state: "fail",
        note:
          error instanceof Error
            ? error.message.split("\n").slice(-3).join(" ").slice(0, 300)
            : String(error),
      });
    }
  }

  async function handleReloadAll() {
    for (const ext of extensions) {
      set(ext.name, { state: "building" });
      try {
        await reloadExtension(ext);
        set(ext.name, { state: "ok" });
      } catch (error) {
        set(ext.name, {
          state: "fail",
          note:
            error instanceof Error
              ? error.message.split("\n").slice(-3).join(" ").slice(0, 200)
              : String(error),
        });
      }
    }
  }

  const accessoryFor = (name: string): List.Item.Accessory[] => {
    const s = status[name];
    if (!s) return [];
    if (s.state === "building")
      return [{ tag: { value: "Building…", color: Color.Yellow } }];
    if (s.state === "ok")
      return [{ tag: { value: s.note ?? "rebuilt", color: Color.Green } }];
    return [{ tag: { value: "failed", color: Color.Red }, tooltip: s.note }];
  };

  const actions = (ext?: Extension) => (
    <ActionPanel>
      {ext && (
        <Action
          title={`Rebuild ${ext.name}`}
          icon={Icon.ArrowClockwise}
          onAction={() => void handleReload(ext)}
        />
      )}
      <Action
        title="Rebuild All"
        icon={Icon.ArrowClockwise}
        onAction={() => void handleReloadAll()}
      />
      {ext && <Action.ShowInFinder title="Open Source Folder" path={ext.dir} />}
    </ActionPanel>
  );

  return (
    <List
      isLoading={busy}
      navigationTitle="Reload Extensions"
      searchBarPlaceholder="Filter extensions…"
    >
      <List.EmptyView
        icon={Icon.Folder}
        title="No extensions found"
        description={`Nothing with a package.json under ${root}. Set the folder in this command's preferences.`}
      />
      <List.Item
        title="All Extensions"
        subtitle={`${extensions.length} in ${root.replace(homedir(), "~")}`}
        icon={{ source: Icon.ArrowClockwise, tintColor: Color.Blue }}
        actions={actions()}
      />
      {extensions.map((ext) => (
        <List.Item
          key={ext.name}
          title={ext.name}
          subtitle={`${ext.commands} command${ext.commands === 1 ? "" : "s"}`}
          icon={ext.icon}
          accessories={accessoryFor(ext.name)}
          actions={actions(ext)}
        />
      ))}
    </List>
  );
}
