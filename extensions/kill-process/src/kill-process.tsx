import {
  Action,
  ActionPanel,
  Alert,
  Color,
  Icon,
  Keyboard,
  List,
  confirmAlert,
  getPreferenceValues,
  showHUD,
} from "@raycast/api";
import { execFile } from "node:child_process";
import { userInfo } from "node:os";
import { useCallback, useEffect, useState } from "react";
import { promisify } from "node:util";

const run = promisify(execFile);

type Scope = "apps" | "mine" | "all";
type Sort = "memory" | "cpu";

interface Preferences {
  scope: Scope;
  sort: Sort;
  confirmForceKill: boolean;
}

interface Process {
  pid: number;
  cpu: number;
  /** Resident set size in MB — what the process actually occupies in RAM. */
  memory: number;
  user: string;
  /** Absolute path of the executable, which is what makes the owning bundle recoverable. */
  path: string;
  /** The executable's own name: "Google Chrome Helper (Renderer)". */
  name: string;
  /** The outermost `.app` on the path, so a helper is filed under the app that spawned it. */
  app?: string;
  /** Path of that bundle, for the icon and for Show in Finder. */
  bundle?: string;
  /** A process whose executable sits directly in the outermost bundle — the app itself. */
  isApp: boolean;
}

const ME = userInfo().username;

/**
 * `comm` is the full executable path, and the four numeric/user fields before it never contain a
 * space — so everything past the fourth is the path, spaces and all. The harness `ps` on PATH is
 * not BSD ps and truncates `comm` to a bare name, so this asks for /bin/ps by absolute path.
 */
async function list(): Promise<Process[]> {
  const { stdout } = await run("/bin/ps", ["-Ao", "pid=,pcpu=,rss=,user=,stat=,comm="], {
    maxBuffer: 16 * 1024 * 1024,
  });

  const processes: Process[] = [];
  for (const line of stdout.split("\n")) {
    const match = /^\s*(\d+)\s+(\S+)\s+(\d+)\s+(\S+)\s+(\S+)\s+(.+)$/.exec(line);
    if (!match) continue;
    const [, pid, cpu, rss, user, state, path] = match;
    // A `Z` has already exited and is only waiting to be reaped: it cannot be signalled, and
    // listing it is how a killed process appears to survive.
    if (state.startsWith("Z")) continue;
    processes.push({
      pid: Number(pid),
      cpu: Number(cpu),
      memory: Number(rss) / 1024,
      user,
      path,
      name: path.slice(path.lastIndexOf("/") + 1),
      ...bundleOf(path),
    });
  }
  return processes;
}

/**
 * Bundles nest: Dia's renderer lives in `Dia.app/…/Browser Helper (Renderer).app/…`. The *outermost*
 * bundle is the one a person recognises, so that is what the row is filed and iconned under.
 */
function bundleOf(path: string): Pick<Process, "app" | "bundle" | "isApp"> {
  const end = path.indexOf(".app/");
  if (end < 0) return { isApp: false };
  const bundle = path.slice(0, end + 4);
  const app = bundle.slice(bundle.lastIndexOf("/") + 1, -4);
  return { app, bundle, isApp: path === `${bundle}/Contents/MacOS/${app}` };
}

function signal(process: Process, sig: "TERM" | "KILL"): Promise<unknown> {
  return run("/bin/kill", [`-${sig}`, String(process.pid)]);
}

function stderrOf(error: unknown): string {
  return error && typeof error === "object" && "stderr" in error && typeof error.stderr === "string"
    ? error.stderr
    : String(error);
}

/**
 * The process was already gone. That is the outcome the user asked for, so it is reported as one -
 * a row can name a pid that exited between the last refresh and the keystroke.
 */
function alreadyGone(error: unknown): boolean {
  return /No such process/i.test(stderrOf(error));
}

/** Otherwise the only interesting failure is ownership, which sudo - not a retry - fixes. */
function explain(error: unknown, process: Process): string {
  const stderr = stderrOf(error);
  if (/Operation not permitted/i.test(stderr)) {
    return `${process.name} runs as ${process.user}; signalling it needs sudo.`;
  }
  return stderr.trim() || "kill failed";
}

export default function Command() {
  const preferences = getPreferenceValues<Preferences>();
  const [processes, setProcesses] = useState<Process[]>([]);
  const [loading, setLoading] = useState(true);
  const [scope, setScope] = useState<Scope>(preferences.scope ?? "apps");
  const [sort, setSort] = useState<Sort>(preferences.sort ?? "memory");
  // Signalled pids, hidden while they die. A dying process keeps appearing in `ps` for a few
  // hundred milliseconds - measured 255-704 ms - so without this the row a kill just removed is
  // put straight back by the refresh that follows it, and the kill reads as having failed.
  const [killed, setKilled] = useState<ReadonlySet<number>>(new Set());

  const refresh = useCallback(async () => {
    try {
      const fresh = await list();
      setProcesses(fresh);
      // Stop hiding a pid once it is really gone: keeping it would hide an unrelated process
      // that the kernel later gives the same number to.
      setKilled((current) => {
        if (current.size === 0) return current;
        const alive = new Set(fresh.map((p) => p.pid));
        const next = new Set([...current].filter((pid) => alive.has(pid)));
        return next.size === current.size ? current : next;
      });
    } catch (error) {
      await showHUD(`Could not read the process table — ${String(error)}`);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  const kill = useCallback(
    async (target: Process, force: boolean) => {
      if (force && preferences.confirmForceKill) {
        const confirmed = await confirmAlert({
          title: `Force kill ${target.name}?`,
          message: "SIGKILL cannot be caught, so the process gets no chance to save its work.",
          icon: Icon.ExclamationMark,
          primaryAction: { title: "Force Kill", style: Alert.ActionStyle.Destructive },
        });
        if (!confirmed) return;
      }

      const hide = () => setKilled((current) => new Set(current).add(target.pid));
      const unhide = () =>
        setKilled((current) => {
          const next = new Set(current);
          next.delete(target.pid);
          return next;
        });

      try {
        await signal(target, force ? "KILL" : "TERM");
        hide();
        await showHUD(`${force ? "Killed" : "Quit"} ${target.name} · pid ${target.pid}`);
      } catch (error) {
        if (alreadyGone(error)) {
          hide();
          await showHUD(`${target.name} had already exited`);
        } else {
          await showHUD(`Could not ${force ? "kill" : "quit"} ${target.name} — ${explain(error, target)}`);
          return;
        }
      }

      // SIGTERM is catchable, so "signalled" is not "gone". Give it the time a dying process
      // actually takes - measured at 255-704 ms - then let the truth back in: a process still
      // there ignored the request, and hiding it forever would be a lie the user acts on.
      const settled = Promise.withResolvers<void>();
      setTimeout(settled.resolve, 1200);
      await settled.promise;

      // One read of the table answers both questions: what to show, and whether it survived.
      const fresh = await list();
      setProcesses(fresh);
      if (fresh.some((p) => p.pid === target.pid)) {
        unhide();
        await showHUD(
          force
            ? `${target.name} is still running — it cannot be killed without sudo`
            : `${target.name} ignored the quit request — try ⌘⇧X to force it`,
        );
      } else {
        unhide(); // Gone from `ps`, so there is nothing left to hide - and the pid may be reused.
      }
    },
    [preferences.confirmForceKill],
  );

  const visible = processes
    .filter((p) => !killed.has(p.pid))
    .filter((p) => (scope === "apps" ? p.isApp : scope === "mine" ? p.user === ME : true))
    .sort((a, b) => (sort === "memory" ? b.memory - a.memory : b.cpu - a.cpu));

  const total = visible.reduce((sum, p) => sum + p.memory, 0);

  return (
    <List
      isLoading={loading}
      searchBarPlaceholder={`Filter ${visible.length} processes by name…`}
      navigationTitle={`${visible.length} processes · ${total.toFixed(0)} MB`}
      searchBarAccessory={
        <List.Dropdown tooltip="Scope" value={scope} onChange={(value) => setScope(value as Scope)}>
          <List.Dropdown.Item title="Apps" value="apps" icon={Icon.Window} />
          <List.Dropdown.Item title="Mine" value="mine" icon={Icon.Person} />
          <List.Dropdown.Item title="All" value="all" icon={Icon.List} />
        </List.Dropdown>
      }
    >
      <List.EmptyView
        icon={Icon.MagnifyingGlass}
        title={loading ? "Reading the process table…" : "Nothing running in this scope"}
        description={scope === "apps" ? "Switch the scope to Mine or All to see helpers and daemons." : undefined}
      />
      {visible.map((process) => (
        <List.Item
          key={process.pid}
          icon={process.bundle ? { fileIcon: process.bundle } : Icon.Terminal}
          title={process.name}
          subtitle={process.app && process.app !== process.name ? process.app : undefined}
          keywords={[String(process.pid), process.user, ...(process.app ? [process.app] : [])]}
          accessories={[
            { text: `${process.cpu.toFixed(1)}%`, icon: Icon.ComputerChip, tooltip: "CPU" },
            {
              tag: {
                value: `${process.memory.toFixed(0)} MB`,
                color: process.memory > 1024 ? Color.Orange : Color.SecondaryText,
              },
              tooltip: "Resident memory",
            },
            { text: String(process.pid), tooltip: `Owned by ${process.user}` },
          ]}
          actions={
            <ActionPanel>
              <ActionPanel.Section>
                <Action
                  title="Quit"
                  icon={Icon.XMarkCircle}
                  onAction={() => kill(process, false)}
                />
                <Action
                  title="Force Kill"
                  icon={Icon.Trash}
                  style={Action.Style.Destructive}
                  shortcut={{ modifiers: ["cmd", "shift"], key: "x" }}
                  onAction={() => kill(process, true)}
                />
              </ActionPanel.Section>
              <ActionPanel.Section>
                <Action
                  title={sort === "memory" ? "Sort by CPU" : "Sort by Memory"}
                  icon={Icon.ArrowUp}
                  shortcut={{ modifiers: ["cmd"], key: "s" }}
                  onAction={() => setSort(sort === "memory" ? "cpu" : "memory")}
                />
                <Action
                  title="Refresh"
                  icon={Icon.ArrowClockwise}
                  shortcut={Keyboard.Shortcut.Common.Refresh}
                  onAction={refresh}
                />
              </ActionPanel.Section>
              <ActionPanel.Section>
                <Action.CopyToClipboard
                  title="Copy PID"
                  content={String(process.pid)}
                  shortcut={{ modifiers: ["cmd"], key: "." }}
                />
                <Action.CopyToClipboard title="Copy Path" content={process.path} />
                <Action.ShowInFinder path={process.bundle ?? process.path} />
              </ActionPanel.Section>
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
