import {
  Action,
  ActionPanel,
  Alert,
  Clipboard,
  Color,
  Icon,
  List,
  Toast,
  confirmAlert,
  getPreferenceValues,
  openExtensionPreferences,
  showToast,
} from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const GH_CANDIDATE_PATHS = [
  "/opt/homebrew/bin/gh",
  "/usr/local/bin/gh",
  "/opt/homebrew/sbin/gh",
  "/usr/bin/gh",
];

interface Prefs {
  forkRepo: string;
  sourceRepo?: string;
  forkBranch?: string;
  sourceBranch?: string;
  ghPath?: string;
}

interface Commit {
  sha: string;
  message: string;
  author: string;
  date: string;
  url: string;
}

interface SyncStatus {
  fork: string;
  source: string;
  forkBranch: string;
  sourceBranch: string;
  behind: number; // upstream commits the fork is missing
  ahead: number; // fork-only commits not upstream
  compareUrl: string;
  missing: Commit[]; // the upstream commits to pull (== behind)
}

function resolveGhPath(override?: string): string {
  const trimmed = override?.trim();
  if (trimmed) {
    if (existsSync(trimmed)) return trimmed;
    throw new Error(`gh not found at configured path: ${trimmed}`);
  }
  const found = GH_CANDIDATE_PATHS.find((p) => existsSync(p));
  if (!found)
    throw new Error("gh CLI not found. Install it with: brew install gh");
  return found;
}

const ghEnv = () => ({
  ...process.env,
  PATH: `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${process.env.PATH ?? ""}`,
});

async function gh(args: string[], ghPath: string): Promise<string> {
  try {
    const { stdout } = await execFileAsync(ghPath, args, {
      env: ghEnv(),
      maxBuffer: 8 * 1024 * 1024,
    });
    return stdout;
  } catch (error) {
    const err = error as { stderr?: string; message?: string };
    const detail = (err.stderr || err.message || String(error))
      .split("\n")
      .map((l) => l.trim())
      .filter(Boolean)
      .slice(-2)
      .join(" ");
    throw new Error(detail || "gh command failed");
  }
}

async function ghApi<T>(path: string, ghPath: string): Promise<T> {
  const out = await gh(["api", "-H", "Accept: application/vnd.github+json", path], ghPath);
  return JSON.parse(out) as T;
}

function normalizeRepo(raw: string | undefined, label: string): string {
  const repo = raw?.trim().replace(/\.git$/i, "").replace(/^https?:\/\/github\.com\//i, "");
  if (!repo) throw new Error(`${label} is not set. Configure it in preferences.`);
  if (!/^[^/\s]+\/[^/\s]+$/.test(repo))
    throw new Error(`${label} must be in owner/name format (got "${raw}").`);
  return repo;
}

async function loadStatus(prefs: Prefs): Promise<SyncStatus> {
  const ghPath = resolveGhPath(prefs.ghPath);
  const fork = normalizeRepo(prefs.forkRepo, "Fork Repository");

  // Fork metadata: default branch + parent (for source auto-detection).
  const forkMeta = await ghApi<{
    default_branch: string;
    fork?: boolean;
    parent?: { full_name: string };
  }>(`repos/${fork}`, ghPath);

  let source: string;
  if (prefs.sourceRepo?.trim()) {
    source = normalizeRepo(prefs.sourceRepo, "Source Repository");
  } else if (forkMeta.parent?.full_name) {
    source = forkMeta.parent.full_name;
  } else {
    throw new Error(
      `No Source Repository set and ${fork} has no detectable parent on GitHub. Set it in preferences.`,
    );
  }

  const sourceMeta = await ghApi<{ default_branch: string }>(
    `repos/${source}`,
    ghPath,
  );

  const forkBranch = prefs.forkBranch?.trim() || forkMeta.default_branch;
  const sourceBranch = prefs.sourceBranch?.trim() || sourceMeta.default_branch;

  const [forkOwner] = fork.split("/");
  const [sourceOwner] = source.split("/");

  // Compare hosted on the source repo, base = fork, head = source.
  // Relative to base (the fork):
  //   ahead_by  = commits head(source) has that base(fork) lacks  -> fork is BEHIND by this many
  //   behind_by = commits base(fork) has that head(source) lacks  -> fork is AHEAD by this many
  //   commits[] = the source commits missing from the fork (exactly what to pull)
  const basehead = `${forkOwner}:${forkBranch}...${sourceOwner}:${sourceBranch}`;
  const cmp = await ghApi<{
    ahead_by: number;
    behind_by: number;
    html_url: string;
    commits: Array<{
      sha: string;
      html_url: string;
      commit: { message: string; author?: { name?: string; date?: string } };
      author?: { login?: string } | null;
    }>;
  }>(`repos/${source}/compare/${basehead}`, ghPath);

  const missing: Commit[] = cmp.commits
    .map((c) => ({
      sha: c.sha,
      message: c.commit.message.split("\n")[0],
      author: c.author?.login || c.commit.author?.name || "unknown",
      date: c.commit.author?.date || "",
      url: c.html_url,
    }))
    .reverse(); // newest first

  return {
    fork,
    source,
    forkBranch,
    sourceBranch,
    behind: cmp.ahead_by,
    ahead: cmp.behind_by,
    compareUrl: cmp.html_url,
    missing,
  };
}

function relativeTime(iso: string): string {
  if (!iso) return "";
  const then = new Date(iso).getTime();
  if (Number.isNaN(then)) return "";
  const secs = Math.max(0, Math.round((Date.now() - then) / 1000));
  const units: [number, string][] = [
    [60, "s"],
    [60, "m"],
    [24, "h"],
    [7, "d"],
    [4.348, "w"],
    [12, "mo"],
    [Number.POSITIVE_INFINITY, "y"],
  ];
  let value = secs;
  let unit = "s";
  for (const [factor, label] of units) {
    if (value < factor) {
      unit = label;
      break;
    }
    value = value / factor;
    unit = label;
  }
  return `${Math.round(value)}${unit} ago`;
}

interface Summary {
  label: string;
  color: Color;
  icon: Icon;
}

function summarize(s: SyncStatus): Summary {
  if (s.behind === 0 && s.ahead === 0)
    return { label: "In sync", color: Color.Green, icon: Icon.CheckCircle };
  if (s.behind > 0 && s.ahead > 0)
    return {
      label: `Diverged · ${s.behind} behind · ${s.ahead} ahead`,
      color: Color.Red,
      icon: Icon.Warning,
    };
  if (s.behind > 0)
    return {
      label: `${s.behind} behind`,
      color: Color.Orange,
      icon: Icon.ArrowDownCircle,
    };
  return {
    label: `${s.ahead} ahead`,
    color: Color.Blue,
    icon: Icon.ArrowUpCircle,
  };
}

export default function Command() {
  const prefs = getPreferenceValues<Prefs>();

  const { data, isLoading, error, revalidate } = useCachedPromise(loadStatus, [
    prefs,
  ]);

  if (error) {
    return (
      <List>
        <List.EmptyView
          icon={{ source: Icon.Warning, tintColor: Color.Red }}
          title="Could not check sync status"
          description={error.message}
          actions={
            <ActionPanel>
              <Action
                title="Open Extension Preferences"
                icon={Icon.Gear}
                onAction={openExtensionPreferences}
              />
              <Action
                title="Retry"
                icon={Icon.ArrowClockwise}
                onAction={() => revalidate()}
              />
            </ActionPanel>
          }
        />
      </List>
    );
  }

  const summary = data ? summarize(data) : undefined;

  const syncCommand = data
    ? `gh repo sync ${data.fork} --source ${data.source} --branch ${data.forkBranch}`
    : "";

  async function syncNow() {
    if (!data) return;
    const ok = await confirmAlert({
      title: "Sync fork now?",
      message: `Fast-forward ${data.fork}@${data.forkBranch} to ${data.source}@${data.sourceBranch} via \`gh repo sync\`.`,
      primaryAction: { title: "Sync", style: Alert.ActionStyle.Default },
    });
    if (!ok) return;
    const toast = await showToast({
      style: Toast.Style.Animated,
      title: "Syncing fork…",
    });
    try {
      const ghPath = resolveGhPath(prefs.ghPath);
      await gh(
        [
          "repo",
          "sync",
          data.fork,
          "--source",
          data.source,
          "--branch",
          data.forkBranch,
        ],
        ghPath,
      );
      toast.style = Toast.Style.Success;
      toast.title = "Fork synced";
      revalidate();
    } catch (e) {
      toast.style = Toast.Style.Failure;
      toast.title = "Sync failed";
      toast.message = e instanceof Error ? e.message : String(e);
    }
  }

  const sharedActions = data && (
    <>
      <Action.OpenInBrowser
        title="Open Comparison on GitHub"
        url={data.compareUrl}
        icon={Icon.CodeBlock}
      />
      <Action
        title="Sync Fork Now"
        icon={Icon.Download}
        shortcut={{ modifiers: ["cmd"], key: "s" }}
        onAction={syncNow}
      />
      <Action
        title="Copy Sync Command"
        icon={Icon.Clipboard}
        shortcut={{ modifiers: ["cmd"], key: "." }}
        onAction={() => Clipboard.copy(syncCommand)}
      />
      <Action.OpenInBrowser
        title="Open Fork on GitHub"
        url={`https://github.com/${data.fork}`}
        icon={Icon.Person}
      />
      <Action.OpenInBrowser
        title="Open Source on GitHub"
        url={`https://github.com/${data.source}`}
        icon={Icon.House}
      />
      <Action
        title="Refresh"
        icon={Icon.ArrowClockwise}
        shortcut={{ modifiers: ["cmd"], key: "r" }}
        onAction={() => revalidate()}
      />
      <Action
        title="Open Extension Preferences"
        icon={Icon.Gear}
        shortcut={{ modifiers: ["cmd"], key: "," }}
        onAction={openExtensionPreferences}
      />
    </>
  );

  return (
    <List isLoading={isLoading} navigationTitle="Fork Sync Status">
      {data && summary && (
        <List.Section title="Status">
          <List.Item
            icon={{ source: summary.icon, tintColor: summary.color }}
            title={`${data.fork} @ ${data.forkBranch}`}
            subtitle={`vs ${data.source} @ ${data.sourceBranch}`}
            accessories={[{ tag: { value: summary.label, color: summary.color } }]}
            actions={<ActionPanel>{sharedActions}</ActionPanel>}
          />
        </List.Section>
      )}
      {data && (
        <List.Section
          title={
            data.behind
              ? `Commits to pull (${data.behind})` +
                (data.missing.length < data.behind
                  ? ` · showing first ${data.missing.length}`
                  : "")
              : "Up to date"
          }
        >
          {data.missing.length === 0 && !isLoading && (
            <List.Item
              icon={{ source: Icon.CheckCircle, tintColor: Color.Green }}
              title="No upstream commits to pull"
              subtitle={
                data.ahead > 0
                  ? `Fork is ${data.ahead} commit(s) ahead of source`
                  : "Fork matches source"
              }
              actions={<ActionPanel>{sharedActions}</ActionPanel>}
            />
          )}
          {data.missing.map((c) => (
            <List.Item
              key={c.sha}
              icon={Icon.Dot}
              title={c.message}
              subtitle={c.sha.slice(0, 7)}
              accessories={[
                { text: c.author },
                { text: relativeTime(c.date) },
              ]}
              actions={
                <ActionPanel>
                  <Action.OpenInBrowser
                    title="Open Commit on GitHub"
                    url={c.url}
                    icon={Icon.CodeBlock}
                  />
                  <Action.CopyToClipboard title="Copy SHA" content={c.sha} />
                  {sharedActions}
                </ActionPanel>
              }
            />
          ))}
        </List.Section>
      )}
    </List>
  );
}
