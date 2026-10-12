import {
  Action,
  ActionPanel,
  Color,
  Detail,
  Icon,
  List,
  Toast,
  getPreferenceValues,
  openCommandPreferences,
  openExtensionPreferences,
  showToast,
} from "@raycast/api";
import { useCachedPromise, type MutatePromise } from "@raycast/utils";
import { execFile, spawn } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { useEffect, useMemo, useRef, useState } from "react";

const execFileAsync = promisify(execFile);

const GH_CANDIDATE_PATHS = [
  "/opt/homebrew/bin/gh",
  "/usr/local/bin/gh",
  "/opt/homebrew/sbin/gh",
  "/usr/bin/gh",
];

interface CommandPrefs {
  repo?: string;
  excludeRepo?: string;
}
interface ExtensionPrefs {
  ghPath?: string;
  accounts?: "active" | "all";
  reviewScript?: string;
  claudePath?: string;
  reviewPrompt?: string;
}

interface PR {
  id: string;
  number: number;
  title: string;
  url: string;
  isDraft: boolean;
  author: string;
  updatedAt: string;
  repo: string;
  account: string;
  host: string;
}

interface GhAccount {
  host: string;
  user: string;
}

type Section = "mine" | "review" | "in-progress" | "merged";

interface PRData {
  mine: PR[];
  review: PR[];
  inProgress: PR[];
  merged: PR[];
  accounts: GhAccount[];
  errors: string[];
}

function resolveGhPath(): string | null {
  const ext = getPreferenceValues<ExtensionPrefs>();
  const override = ext.ghPath?.trim();
  if (override && existsSync(override)) return override;
  return GH_CANDIDATE_PATHS.find((p) => existsSync(p)) ?? null;
}

const tokenCache = new Map<string, string>();
let accountsCache: { active: GhAccount[]; all: GhAccount[] } | null = null;
async function getAccountToken(account: GhAccount): Promise<string> {
  const key = `${account.host}\u0000${account.user}`;
  const cached = tokenCache.get(key);
  if (cached) return cached;
  const gh = resolveGhPath();
  if (!gh) throw new Error("gh CLI not found. Install via: brew install gh");
  const env = {
    ...process.env,
    PATH: `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${process.env.PATH ?? ""}`,
  };
  const { stdout } = await execFileAsync(
    gh,
    ["auth", "token", "--hostname", account.host, "--user", account.user],
    { env, maxBuffer: 1024 * 1024 },
  );
  const token = stdout.trim();
  if (!token)
    throw new Error(`Empty token for ${account.user}@${account.host}`);
  tokenCache.set(key, token);
  return token;
}

async function listGhAccounts(
  mode: "active" | "all" = "active",
): Promise<GhAccount[]> {
  if (accountsCache) return accountsCache[mode];

  // Parse ~/.config/gh/hosts.yml directly instead of shelling out to
  // `gh auth status`, which validates every token over the network and adds
  // ~1.5–2s to every refresh.
  const hostsPath = path.join(homedir(), ".config", "gh", "hosts.yml");
  if (!existsSync(hostsPath)) {
    throw new Error("No gh config found. Run: gh auth login");
  }
  let raw = "";
  try {
    raw = readFileSync(hostsPath, "utf8");
  } catch (e) {
    throw new Error(`Failed to read ${hostsPath}: ${(e as Error).message}`);
  }

  const all: GhAccount[] = [];
  const activeByHost: Record<string, string> = {};
  const seen = new Set<string>();
  let currentHost: string | null = null;
  let inUsers = false;
  let usersIndent = -1;
  for (const line of raw.split(/\r?\n/)) {
    if (!line.trim()) continue;
    const indent = line.match(/^(\s*)/)?.[1].length ?? 0;
    const hostMatch = indent === 0 ? line.match(/^([^\s:]+):\s*$/) : null;
    if (hostMatch) {
      currentHost = hostMatch[1];
      inUsers = false;
      usersIndent = -1;
      continue;
    }
    if (!currentHost) continue;

    // `user: <name>` under a host marks the active account for that host.
    if (!inUsers || indent <= usersIndent) {
      const am = line.match(/^\s+user:\s+(\S+)\s*$/);
      if (am) {
        activeByHost[currentHost] = am[1];
        inUsers = false;
        continue;
      }
    }

    if (/^\s+users:\s*$/.test(line)) {
      inUsers = true;
      usersIndent = indent;
      continue;
    }
    if (inUsers) {
      if (indent > usersIndent) {
        const um = line.match(/^\s+([^\s:]+):\s*$/);
        if (um) {
          const user = um[1];
          const key = `${currentHost}\u0000${user}`;
          if (!seen.has(key)) {
            seen.add(key);
            all.push({ host: currentHost, user });
          }
        }
      } else {
        inUsers = false;
      }
    }
  }

  // Fallback for older single-account configs without a nested `users:` block.
  for (const [host, user] of Object.entries(activeByHost)) {
    const key = `${host}\u0000${user}`;
    if (!seen.has(key)) {
      seen.add(key);
      all.push({ host, user });
    }
  }

  const active: GhAccount[] = Object.entries(activeByHost).map(
    ([host, user]) => ({
      host,
      user,
    }),
  );

  accountsCache = { all, active: active.length > 0 ? active : all };
  return accountsCache[mode];
}

function deriveRepoFromUrl(url: string): string {
  // https://<host>/owner/repo/pull/123
  const m = url.match(/\/([^/]+\/[^/]+)\/pull\//);
  return m ? m[1] : "";
}

function parseRepoPatterns(raw?: string): string[] {
  return (raw ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

function hasWildcard(pattern: string): boolean {
  return pattern.includes("*");
}

// Convert a glob-ish repo pattern (owner/name, owner/*, *, owner/legacy-*)
// into a case-insensitive RegExp anchored to the full nameWithOwner string.
function repoPatternToRegExp(pattern: string): RegExp {
  const escaped = pattern
    .replace(/[.+^${}()|[\]\\]/g, "\\$&")
    .replace(/\*/g, ".*");
  return new RegExp(`^${escaped}$`, "i");
}

function matchesAnyPattern(repo: string, patterns: RegExp[]): boolean {
  return patterns.some((re) => re.test(repo));
}

function repoAllowed(
  repo: string,
  includes: RegExp[],
  excludes: RegExp[],
): boolean {
  if (includes.length > 0 && !matchesAnyPattern(repo, includes)) return false;
  if (excludes.length > 0 && matchesAnyPattern(repo, excludes)) return false;
  return true;
}

function relativeTime(iso: string): string {
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return "";
  const secs = Math.floor((Date.now() - t) / 1000);
  if (secs < 60) return "just now";
  if (secs < 3600) return `${Math.floor(secs / 60)}m ago`;
  if (secs < 86400) return `${Math.floor(secs / 3600)}h ago`;
  return `${Math.floor(secs / 86400)}d ago`;
}

async function fetchPRsForAccount(
  includes: string[],
  excludes: string[],
  account: GhAccount,
): Promise<{ mine: PR[]; review: PR[]; inProgress: PR[]; merged: PR[] }> {
  // One GraphQL request per account that runs three aliased `search` queries in
  // parallel server-side. Going via HTTPS skips ~3 gh subprocess spawns per
  // account (each ~150-300ms cold-start), which made the previous CLI-based
  // implementation feel slow.
  //
  // Exact include patterns (no wildcard) are pushed server-side as `repo:`
  // qualifiers for efficiency. Wildcard includes and all excludes are resolved
  // client-side via glob matching, since GitHub search can't express repo
  // globs directly.
  const includeRes = includes.map(repoPatternToRegExp);
  const excludeRes = excludes.map(repoPatternToRegExp);
  const anyWildcardInclude = includes.some(hasWildcard);
  const exactIncludes = includes.filter((p) => !hasWildcard(p));
  const repoQual = anyWildcardInclude
    ? ""
    : exactIncludes.map((r) => `repo:${r}`).join(" ");
  const qMine = `is:pr is:open author:@me ${repoQual}`.trim();
  // PRs explicitly assigned to the user, regardless of who authored them.
  const qAssigned = `is:pr is:open assignee:@me -author:@me ${repoQual}`.trim();
  // `user-review-requested:@me` matches only PRs where you were requested
  // directly/individually. Plain `review-requested:@me` would also include PRs
  // requested via a team you belong to.
  const qReview = `is:pr is:open user-review-requested:@me ${repoQual}`.trim();
  const qInProgress =
    `is:pr is:open reviewed-by:@me -author:@me ${repoQual}`.trim();
  // Recently merged PRs authored by the user, most recently updated first.
  const qMerged =
    `is:pr is:merged author:@me sort:updated-desc ${repoQual}`.trim();
  // Merged PRs assigned to the user regardless of who authored them.
  const qMergedAssigned =
    `is:pr is:merged assignee:@me -author:@me sort:updated-desc ${repoQual}`.trim();

  const query = `
    fragment PRFields on PullRequest {
      number
      title
      url
      isDraft
      updatedAt
      author { login }
      repository { nameWithOwner isArchived }
    }
    query($qMine: String!, $qAssigned: String!, $qReview: String!, $qInProgress: String!, $qMerged: String!, $qMergedAssigned: String!) {
      mine: search(query: $qMine, type: ISSUE, first: 50) {
        nodes { __typename ... on PullRequest { ...PRFields } }
      }
      assigned: search(query: $qAssigned, type: ISSUE, first: 50) {
        nodes { __typename ... on PullRequest { ...PRFields } }
      }
      review: search(query: $qReview, type: ISSUE, first: 50) {
        nodes { __typename ... on PullRequest { ...PRFields } }
      }
      inProgress: search(query: $qInProgress, type: ISSUE, first: 50) {
        nodes {
          __typename
          ... on PullRequest {
            ...PRFields
            viewerLatestReview { state }
          }
        }
      }
      merged: search(query: $qMerged, type: ISSUE, first: 50) {
        nodes { __typename ... on PullRequest { ...PRFields } }
      }
      mergedAssigned: search(query: $qMergedAssigned, type: ISSUE, first: 50) {
        nodes { __typename ... on PullRequest { ...PRFields } }
      }
    }
  `;

  type GqlNode = {
    __typename?: string;
    number?: number;
    title?: string;
    url?: string;
    isDraft?: boolean;
    updatedAt?: string;
    author?: { login?: string } | null;
    repository?: { nameWithOwner?: string; isArchived?: boolean } | null;
    viewerLatestReview?: { state?: string } | null;
  };
  type GqlResponse = {
    data?: {
      mine?: { nodes?: GqlNode[] };
      assigned?: { nodes?: GqlNode[] };
      review?: { nodes?: GqlNode[] };
      inProgress?: { nodes?: GqlNode[] };
      merged?: { nodes?: GqlNode[] };
      mergedAssigned?: { nodes?: GqlNode[] };
    };
    errors?: { message?: string }[];
  };

  const json = await graphqlRequest<GqlResponse>(account, query, {
    qMine,
    qAssigned,
    qReview,
    qInProgress,
    qMerged,
    qMergedAssigned,
  });
  if (json.errors?.length) {
    throw new Error(
      json.errors.map((e) => e.message ?? "GraphQL error").join("; "),
    );
  }

  const toPR = (n: GqlNode): PR => {
    const repo = n.repository?.nameWithOwner ?? deriveRepoFromUrl(n.url ?? "");
    return {
      id: `${account.host}#${repo}#${n.number}`,
      number: n.number ?? 0,
      title: n.title ?? "",
      url: n.url ?? "",
      isDraft: !!n.isDraft,
      author: n.author?.login ?? "unknown",
      updatedAt: n.updatedAt ?? new Date().toISOString(),
      repo,
      account: account.user,
      host: account.host,
    };
  };
  // Drop PRs from archived repositories — they're read-only and shouldn't
  // clutter the open/review lists.
  const pickPRs = (nodes: GqlNode[] | undefined): GqlNode[] =>
    (nodes ?? []).filter(
      (n) => n.__typename === "PullRequest" && !n.repository?.isArchived,
    );

  const inProgress = pickPRs(json.data?.inProgress?.nodes).filter((n) => {
    const s = n.viewerLatestReview?.state;
    return s === "COMMENTED" || s === "CHANGES_REQUESTED";
  });

  const allowed = (pr: PR): boolean =>
    repoAllowed(pr.repo, includeRes, excludeRes);

  const mine = [
    ...pickPRs(json.data?.mine?.nodes),
    ...pickPRs(json.data?.assigned?.nodes),
  ]
    .map(toPR)
    .filter(allowed);

  const merged = [
    ...pickPRs(json.data?.merged?.nodes),
    ...pickPRs(json.data?.mergedAssigned?.nodes),
  ]
    .map(toPR)
    .filter(allowed);

  return {
    mine,
    review: pickPRs(json.data?.review?.nodes).map(toPR).filter(allowed),
    inProgress: inProgress.map(toPR).filter(allowed),
    merged,
  };
}

async function graphqlRequest<T>(
  account: GhAccount,
  query: string,
  variables: Record<string, unknown>,
): Promise<T> {
  const url =
    account.host === "github.com"
      ? "https://api.github.com/graphql"
      : `https://${account.host}/api/graphql`;
  const token = await getAccountToken(account);
  const res = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      Accept: "application/json",
      "User-Agent": "raycast-github-pr-monitor",
    },
    body: JSON.stringify({ query, variables }),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(
      `GraphQL HTTP ${res.status} ${res.statusText}: ${body.slice(0, 200)}`,
    );
  }
  return (await res.json()) as T;
}

async function closePR(pr: PR): Promise<void> {
  const gh = resolveGhPath();
  if (!gh) throw new Error("gh CLI not found. Install via: brew install gh");
  const token = await getAccountToken({ host: pr.host, user: pr.account });
  const env = {
    ...process.env,
    PATH: `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${process.env.PATH ?? ""}`,
    GH_TOKEN: token,
    GH_HOST: pr.host,
  };
  await execFileAsync(
    gh,
    ["pr", "close", String(pr.number), "--repo", `${pr.host}/${pr.repo}`],
    { env, maxBuffer: 1024 * 1024 },
  );
}

async function fetchPRs(
  includes: string[],
  excludes: string[],
): Promise<PRData> {
  const mode = getPreferenceValues<ExtensionPrefs>().accounts ?? "active";
  const candidates = await listGhAccounts(mode);
  if (candidates.length === 0) {
    throw new Error("No logged-in gh accounts. Run: gh auth login");
  }
  // Pre-warm token cache in parallel. Accounts whose token can't be retrieved
  // (e.g. stale hosts.yml entry without a keychain token) are dropped silently
  // — they're not a real failure, just a leftover config stub.
  const probed = await Promise.all(
    candidates.map(async (a) => {
      try {
        await getAccountToken(a);
        return a;
      } catch {
        return null;
      }
    }),
  );
  const accounts = probed.filter((a): a is GhAccount => a !== null);
  if (accounts.length === 0) {
    throw new Error(
      `No usable gh tokens. Run: gh auth login (configured: ${candidates
        .map((c) => `${c.user}@${c.host}`)
        .join(", ")})`,
    );
  }
  const errors: string[] = [];
  const settled = await Promise.all(
    accounts.map(async (acct) => {
      try {
        return await fetchPRsForAccount(includes, excludes, acct);
      } catch (e) {
        errors.push(`${acct.user}@${acct.host}: ${(e as Error).message}`);
        return {
          mine: [] as PR[],
          review: [] as PR[],
          inProgress: [] as PR[],
          merged: [] as PR[],
        };
      }
    }),
  );

  const dedupByUrl = (prs: PR[]): PR[] => {
    const seen = new Set<string>();
    const out: PR[] = [];
    for (const pr of prs) {
      if (seen.has(pr.url)) continue;
      seen.add(pr.url);
      out.push(pr);
    }
    return out.sort(
      (a, b) => Date.parse(b.updatedAt) - Date.parse(a.updatedAt),
    );
  };

  return {
    mine: dedupByUrl(settled.flatMap((s) => s.mine)),
    review: dedupByUrl(settled.flatMap((s) => s.review)),
    inProgress: dedupByUrl(settled.flatMap((s) => s.inProgress)),
    merged: dedupByUrl(settled.flatMap((s) => s.merged)),
    accounts,
    errors,
  };
}

const CLAUDE_CANDIDATE_PATHS = [
  "/opt/homebrew/bin/claude",
  "/usr/local/bin/claude",
  `${homedir()}/.claude/local/claude`,
  `${homedir()}/.local/bin/claude`,
  `${homedir()}/bin/claude`,
];

function resolveClaudePath(override?: string): string | null {
  const trimmed = override?.trim();
  if (trimmed && existsSync(trimmed)) return trimmed;
  return CLAUDE_CANDIDATE_PATHS.find((p) => existsSync(p)) ?? null;
}

async function readClaudeOAuthToken(
  timeoutMs = 90_000,
): Promise<{ token: string; expiresAt?: number } | null> {
  // Pulls the OAuth access token stored by `claude /login` from the macOS
  // keychain. The first time Raycast tries this, macOS pops a one-time
  // "Raycast wants to use the Claude Code-credentials keychain item" dialog;
  // clicking "Always Allow" makes subsequent reads silent.
  // Note: that dialog often appears BEHIND Raycast's popover — the user
  // needs to dismiss Raycast (Esc) to see and approve it.
  return await new Promise((resolve) => {
    const child = execFile(
      "/usr/bin/security",
      ["find-generic-password", "-w", "-s", "Claude Code-credentials"],
      { maxBuffer: 1024 * 64 },
      (err, stdout) => {
        clearTimeout(timer);
        if (err) {
          resolve(null);
          return;
        }
        try {
          const parsed = JSON.parse(stdout.trim()) as {
            claudeAiOauth?: { accessToken?: string; expiresAt?: number };
          };
          const token = parsed.claudeAiOauth?.accessToken;
          if (typeof token !== "string" || token.length === 0) {
            resolve(null);
            return;
          }
          resolve({ token, expiresAt: parsed.claudeAiOauth?.expiresAt });
        } catch {
          resolve(null);
        }
      },
    );
    const timer = setTimeout(() => {
      try {
        child.kill();
      } catch {
        /* ignore */
      }
      resolve(null);
    }, timeoutMs);
  });
}

type ReviewStage = "keychain" | "running" | "done";

function ReviewPRView({ pr }: { pr: PR }) {
  const [output, setOutput] = useState("");
  const [toolLogs, setToolLogs] = useState<string[]>([]);
  const [assistantText, setAssistantText] = useState("");
  const [thinkingText, setThinkingText] = useState("");
  const [eventCount, setEventCount] = useState(0);
  const [showTools, setShowTools] = useState(false);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [exitCode, setExitCode] = useState<number | null>(null);
  const [commandLine, setCommandLine] = useState<string>("");
  const [stage, setStage] = useState<ReviewStage>("keychain");
  const [attempt, setAttempt] = useState(0);
  const [tick, setTick] = useState(0);
  const [savedPath, setSavedPath] = useState<string | null>(null);
  const startedAt = useRef(Date.now());

  // Re-render every second so the elapsed counter ticks while we wait.
  useEffect(() => {
    if (!isLoading) return;
    const id = setInterval(() => setTick((t) => t + 1), 1000);
    return () => clearInterval(id);
  }, [isLoading]);

  // After the review completes, persist the final markdown to a temp file
  // so the user can keep reading it after Raycast auto-closes the window.
  useEffect(() => {
    if (isLoading) return;
    const finalText = (assistantText || output).trim();
    if (!finalText) return;
    try {
      const safeRepo = pr.repo.replace(/[^a-zA-Z0-9._-]+/g, "-");
      const file = path.join(
        tmpdir(),
        `raycast-pr-review-${safeRepo}-${pr.number}.md`,
      );
      const md =
        `# PR Review · ${pr.repo}#${pr.number}\n\n` +
        `**${pr.title}**\n\n` +
        `<${pr.url}>\n\n---\n\n` +
        finalText;
      writeFileSync(file, md, "utf8");
      setSavedPath(file);
    } catch {
      /* ignore disk errors */
    }
  }, [isLoading, assistantText, output, pr.repo, pr.number, pr.title, pr.url]);

  useEffect(() => {
    let mounted = true;
    let cancelled = false;
    startedAt.current = Date.now();
    setOutput("");
    setToolLogs([]);
    setAssistantText("");
    setThinkingText("");
    setEventCount(0);
    setSavedPath(null);
    setError(null);
    setExitCode(null);
    setIsLoading(true);
    setStage("keychain");

    const safeSetOutput = (updater: (prev: string) => string) => {
      if (mounted) setOutput(updater);
    };
    const safeSetError = (msg: string) => {
      if (mounted) setError(msg);
    };
    const safeSetLoading = (v: boolean) => {
      if (mounted) setIsLoading(v);
    };
    const safeSetExit = (c: number | null) => {
      if (mounted) setExitCode(c);
    };

    let child: ReturnType<typeof spawn> | null = null;

    (async () => {
      const prefs = getPreferenceValues<ExtensionPrefs>();
      const userScript = prefs.reviewScript?.trim();

      // Base env passed to the child.
      const env: NodeJS.ProcessEnv = {
        ...process.env,
        PATH: `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${homedir()}/.claude/local:${process.env.PATH ?? ""}`,
        PR_URL: pr.url,
        PR_NUMBER: String(pr.number),
        PR_REPO: pr.repo,
        PR_TITLE: pr.title,
        PR_AUTHOR: pr.author,
        PR_HOST: pr.host,
        PR_ACCOUNT: pr.account,
      };

      const promptTemplate =
        prefs.reviewPrompt?.trim() ||
        [
          "You are reviewing GitHub pull request {URL}.",
          "Use the `gh` CLI (already authenticated) to gather context. Always append",
          "` || true` to inspection commands so non-zero exits (e.g. failing CI from",
          "`gh pr checks`) do not abort the tool call — the output is still useful data.",
          "Suggested commands:",
          "`gh pr view {URL} --json title,body,author,additions,deletions,files,baseRefName,headRefName,state || true`,",
          "`gh pr diff {URL} || true`,",
          "`gh pr checks {URL} || true`.",
          "You may use any tools available (Bash, Read, Grep, WebFetch, etc.).",
          "",
          "Produce a concise markdown code review with:",
          "1. **Summary** — 1–3 sentences on what the PR does.",
          "2. **Findings** — bullet list of concrete issues (correctness, security, performance, style). Cite file:line where possible.",
          "3. **Suggestions** — actionable improvements.",
          "4. **Risks** — things to watch for during rollout.",
          "5. **Verdict** — approve / request changes / needs discussion.",
          "",
          "Be specific. Skip generic advice. Do not modify any files.",
        ].join("\n");
      const prompt = promptTemplate.split("{URL}").join(pr.url);

      // For the built-in claude path we extract the OAuth token from the
      // keychain and inject it as CLAUDE_CODE_OAUTH_TOKEN. This avoids the
      // sandbox-vs-keychain dance and lets us spawn claude directly with
      // streaming output. Custom scripts are run as-is (the user owns auth).
      if (!userScript) {
        const existingToken =
          process.env.CLAUDE_CODE_OAUTH_TOKEN || process.env.ANTHROPIC_API_KEY;
        if (!existingToken) {
          if (mounted) setStage("keychain");
          const creds = await readClaudeOAuthToken();
          if (cancelled) return;
          if (!creds) {
            safeSetError(
              "Could not read Claude credentials from the macOS keychain.\n\n" +
                "**The keychain access dialog likely appeared behind Raycast.** " +
                "Press `Esc` to close Raycast, look for a macOS dialog titled " +
                '"Raycast wants to use confidential information stored in ' +
                "'Claude Code-credentials'\", enter your login password, and click " +
                "**Always Allow**. Then press `⌘R` here to retry.\n\n" +
                "If no dialog appeared at all, run `claude /login` in Terminal first.",
            );
            safeSetLoading(false);
            return;
          }
          env.CLAUDE_CODE_OAUTH_TOKEN = creds.token;
          if (creds.expiresAt && creds.expiresAt < Date.now()) {
            safeSetOutput(
              () =>
                "_⚠️ Your stored Claude OAuth token may have expired. " +
                "If you get an auth error, run `claude /login` again._\n\n",
            );
          }
        }
      }

      let cmd: string;
      let args: string[];
      const useStreamJson = !userScript;
      if (userScript) {
        if (!existsSync(userScript)) {
          safeSetError(`Review script not found: ${userScript}`);
          safeSetLoading(false);
          return;
        }
        cmd = userScript;
        args = [pr.url];
        setCommandLine(`${userScript} ${pr.url}`);
      } else {
        const claude = resolveClaudePath(prefs.claudePath);
        if (!claude) {
          safeSetError(
            "Could not find the `claude` CLI. Install it (https://docs.anthropic.com/claude/docs/cli) or set the Claude CLI Path in extension preferences.",
          );
          safeSetLoading(false);
          return;
        }
        cmd = claude;
        args = [
          "-p",
          prompt,
          // Allow any tool without interactive permission prompts —
          // claude otherwise hangs waiting on stdin (which we route to
          // /dev/null) the moment it wants to call a tool like Bash.
          "--permission-mode",
          "bypassPermissions",
          // Stream events so we can show progress live in the Detail view.
          "--output-format",
          "stream-json",
          "--verbose",
          "--include-partial-messages",
        ];
        setCommandLine(
          `${claude} -p "<prompt>" --permission-mode bypassPermissions --output-format stream-json`,
        );
      }

      if (mounted) setStage("running");
      try {
        child = spawn(cmd, args, {
          env,
          stdio: ["ignore", "pipe", "pipe"],
        });
      } catch (e) {
        safeSetError((e as Error).message);
        safeSetLoading(false);
        return;
      }

      const append = (chunk: Buffer | string) =>
        safeSetOutput((prev) => {
          const next = prev + chunk.toString();
          return next.length > 200_000
            ? next.slice(next.length - 200_000)
            : next;
        });

      if (useStreamJson) {
        // Parse newline-delimited JSON events from claude --output-format
        // stream-json. We update two independent React states: a chronological
        // tool-call log and the assistant's text reply. The Detail view
        // composes them based on the user's show/hide-tools preference.
        let buf = "";
        let localAssistant = "";
        let localThinking = "";
        let localEvents = 0;
        const localTools: string[] = [];
        let pendingFlush = false;
        const scheduleFlush = () => {
          if (pendingFlush || !mounted) return;
          pendingFlush = true;
          setImmediate(() => {
            pendingFlush = false;
            if (!mounted) return;
            setAssistantText(localAssistant);
            setThinkingText(localThinking);
            setEventCount(localEvents);
            setToolLogs(localTools.slice());
          });
        };
        const extractText = (content: unknown): string => {
          if (typeof content === "string") return content;
          if (Array.isArray(content)) {
            return content
              .map((c) => {
                if (c && typeof c === "object" && "text" in c) {
                  const t = (c as { text?: unknown }).text;
                  return typeof t === "string" ? t : "";
                }
                return "";
              })
              .join("");
          }
          return "";
        };
        const handleEvent = (evt: unknown) => {
          if (!evt || typeof evt !== "object") return;
          const e = evt as Record<string, unknown>;
          localEvents++;
          if (e.type === "assistant") {
            const msg = e.message as { content?: unknown } | undefined;
            const content = Array.isArray(msg?.content) ? msg!.content : [];
            // Each assistant event carries the cumulative content so far.
            let text = "";
            for (const block of content as Array<Record<string, unknown>>) {
              if (block.type === "text" && typeof block.text === "string") {
                text += block.text;
              } else if (block.type === "tool_use") {
                const name = String(block.name ?? "tool");
                const input = block.input ? JSON.stringify(block.input) : "";
                const preview =
                  input.length > 160 ? input.slice(0, 160) + "…" : input;
                const line = `🔧 **${name}** \`${preview}\``;
                if (localTools[localTools.length - 1] !== line)
                  localTools.push(line);
              }
            }
            if (text) localAssistant = text;
          } else if (e.type === "stream_event") {
            const inner = e.event as
              | {
                  type?: string;
                  delta?: { type?: string; text?: string; thinking?: string };
                }
              | undefined;
            if (inner?.type === "content_block_delta" && inner.delta) {
              if (
                inner.delta.type === "text_delta" &&
                typeof inner.delta.text === "string"
              ) {
                localAssistant += inner.delta.text;
              } else if (
                inner.delta.type === "thinking_delta" &&
                typeof inner.delta.thinking === "string"
              ) {
                localThinking += inner.delta.thinking;
              }
            }
          } else if (e.type === "user") {
            // tool_result events — show a short marker so the user sees
            // tools are returning data, and surface error text on failure.
            const msg = e.message as { content?: unknown } | undefined;
            const content = Array.isArray(msg?.content) ? msg!.content : [];
            for (const block of content as Array<Record<string, unknown>>) {
              if (block.type === "tool_result") {
                const isErr = block.is_error === true;
                if (isErr) {
                  const text = extractText(block.content).trim();
                  const snippet = text
                    ? text.length > 400
                      ? text.slice(0, 400) + "…"
                      : text
                    : "(no error message)";
                  localTools.push(
                    `❌ tool error: \`${snippet.replace(/`/g, "ʼ")}\``,
                  );
                } else {
                  localTools.push("✅ tool result");
                }
              }
            }
          } else if (e.type === "result") {
            if (typeof e.result === "string" && e.result.length > 0) {
              localAssistant = e.result;
            }
          }
        };
        child.stdout?.on("data", (chunk: Buffer) => {
          buf += chunk.toString();
          let nl;
          while ((nl = buf.indexOf("\n")) >= 0) {
            const line = buf.slice(0, nl).trim();
            buf = buf.slice(nl + 1);
            if (!line) continue;
            try {
              handleEvent(JSON.parse(line));
            } catch {
              // Malformed line — fall back to raw append so user sees it.
              localAssistant += line + "\n";
            }
          }
          scheduleFlush();
        });
        child.stderr?.on("data", append);
      } else {
        child.stdout?.on("data", append);
        child.stderr?.on("data", append);
      }
      child.on("error", (e) => {
        safeSetError(e.message);
        safeSetLoading(false);
      });
      child.on("close", (code) => {
        safeSetExit(code);
        safeSetLoading(false);
        if (mounted) setStage("done");
      });
    })().catch((e) => {
      safeSetError((e as Error).message);
      safeSetLoading(false);
    });

    return () => {
      mounted = false;
      cancelled = true;
      try {
        if (child && child.exitCode == null) child.kill();
      } catch {
        /* ignore */
      }
    };
  }, [pr.url, attempt]);

  // Reference tick so React re-renders every second while loading.
  void tick;
  const elapsed = Math.max(
    0,
    Math.floor((Date.now() - startedAt.current) / 1000),
  );
  const stageLabel =
    stage === "keychain"
      ? "Requesting Claude credentials from keychain… (press Esc if you don't see the dialog)"
      : stage === "running"
        ? `Running Claude review… (${elapsed}s)`
        : `Finished in ${elapsed}s`;
  const header =
    `# PR Review · #${pr.number}\n\n` +
    `**${pr.title}**\n\n` +
    `\`${pr.repo}\` · [Open in browser](${pr.url})\n\n---\n\n`;
  const toolSection = toolLogs.length
    ? showTools
      ? `🔧 **Tool activity (${toolLogs.length})** — ⌘T to hide\n\n` +
        toolLogs.map((l) => `- ${l}`).join("\n") +
        "\n\n---\n\n"
      : `_🔧 ${toolLogs.length} tool call${toolLogs.length === 1 ? "" : "s"} — press ⌘T to show_\n\n`
    : "";
  const thinkingTail = thinkingText.slice(-600);
  const thinkingSection =
    isLoading && !assistantText && thinkingText
      ? `_💭 Claude is thinking… (${eventCount} events received)_\n\n` +
        "> " +
        thinkingTail.replace(/\n+/g, "\n> ") +
        "\n\n"
      : "";
  const streamBody = toolSection + thinkingSection + assistantText;
  const rawBody = output;
  const composed = streamBody || rawBody;
  const body =
    composed ||
    (isLoading ? `_${stageLabel}_` : error == null ? "_(no output)_" : "");
  const footer =
    error != null
      ? `\n\n---\n\n> ⚠️ ${error}`
      : !isLoading && exitCode != null && exitCode !== 0
        ? `\n\n---\n\n> ⚠️ Review process exited with code ${exitCode}.`
        : "";
  const markdown = header + body + footer;

  return (
    <Detail
      isLoading={isLoading}
      navigationTitle={`Review #${pr.number} · ${pr.repo}`}
      markdown={markdown}
      metadata={
        <Detail.Metadata>
          <Detail.Metadata.Label title="Repo" text={pr.repo} />
          <Detail.Metadata.Label title="Author" text={`@${pr.author}`} />
          <Detail.Metadata.Label
            title="Status"
            text={
              isLoading
                ? stage === "keychain"
                  ? `Waiting on keychain… (${elapsed}s)`
                  : `Running… (${elapsed}s)`
                : error != null
                  ? "Error"
                  : exitCode === 0
                    ? `Done (${elapsed}s)`
                    : `Exit ${exitCode ?? "?"}`
            }
          />
          <Detail.Metadata.Link
            title="Pull Request"
            target={pr.url}
            text={`#${pr.number}`}
          />
        </Detail.Metadata>
      }
      actions={
        <ActionPanel>
          <Action.CopyToClipboard
            title="Copy Review"
            content={assistantText || output}
          />
          {savedPath && (
            <Action.Open
              title="Open Review in External Viewer"
              icon={Icon.Window}
              target={savedPath}
              shortcut={{ modifiers: ["cmd"], key: "o" }}
            />
          )}
          {savedPath && (
            <Action.ShowInFinder
              title="Show Review File in Finder"
              path={savedPath}
              shortcut={{ modifiers: ["cmd", "shift"], key: "o" }}
            />
          )}
          <Action
            title={showTools ? "Hide Tool Activity" : "Show Tool Activity"}
            icon={Icon.Terminal}
            shortcut={{ modifiers: ["cmd"], key: "t" }}
            onAction={() => setShowTools((v) => !v)}
          />
          <Action
            title="Retry Review"
            icon={Icon.ArrowClockwise}
            shortcut={{ modifiers: ["cmd"], key: "r" }}
            onAction={() => setAttempt((a) => a + 1)}
          />
          <Action.OpenInBrowser url={pr.url} title="Open PR in Browser" />
          <Action.CopyToClipboard
            title="Copy PR URL"
            content={pr.url}
            shortcut={{ modifiers: ["cmd"], key: "." }}
          />
          <Action
            title="Open Extension Preferences"
            icon={Icon.Gear}
            shortcut={{ modifiers: ["cmd", "shift"], key: "," }}
            onAction={openExtensionPreferences}
          />
        </ActionPanel>
      }
    />
  );
}

function PRListItem({
  pr,
  section,
  showAccount,
  revalidate,
  mutate,
}: {
  pr: PR;
  section: Section;
  showAccount: boolean;
  revalidate: () => void;
  mutate: MutatePromise<PRData | undefined>;
}) {
  const accessories: List.Item.Accessory[] = [];
  if (pr.isDraft) {
    accessories.push({ tag: { value: "DRAFT", color: Color.SecondaryText } });
  }
  if (showAccount) {
    accessories.push({
      tag: { value: pr.account, color: Color.Purple },
      tooltip: `gh account: ${pr.account}@${pr.host}`,
    });
  }
  accessories.push({ text: `@${pr.author}` });
  accessories.push({
    date: new Date(pr.updatedAt),
    tooltip: `Updated ${relativeTime(pr.updatedAt)}`,
  });

  const icon =
    section === "mine"
      ? { source: Icon.Person, tintColor: Color.Blue }
      : section === "review"
        ? { source: Icon.Eye, tintColor: Color.Orange }
        : section === "in-progress"
          ? { source: Icon.SpeechBubble, tintColor: Color.Yellow }
          : { source: Icon.Checkmark, tintColor: Color.Purple };

  return (
    <List.Item
      icon={icon}
      title={pr.title}
      subtitle={`${pr.repo} #${pr.number}`}
      keywords={[String(pr.number), pr.author, pr.repo]}
      accessories={accessories}
      actions={
        <ActionPanel>
          <Action.OpenInBrowser url={pr.url} title="Open PR in Browser" />
          <Action.Push
            title="Review PR with Claude"
            icon={Icon.Stars}
            shortcut={{ modifiers: ["cmd"], key: "y" }}
            target={<ReviewPRView pr={pr} />}
          />
          <Action.CopyToClipboard
            title="Copy PR URL"
            content={pr.url}
            shortcut={{ modifiers: ["cmd"], key: "." }}
          />
          <Action.CopyToClipboard
            title="Copy PR Number"
            content={`#${pr.number}`}
            shortcut={{ modifiers: ["cmd", "shift"], key: "." }}
          />
          <Action.CopyToClipboard
            title="Copy Title"
            content={pr.title}
            shortcut={{ modifiers: ["cmd", "shift"], key: "t" }}
          />
          {section !== "merged" && (
            <ActionPanel.Section>
              <Action
                title="Close PR"
                icon={Icon.XMarkCircle}
                style={Action.Style.Destructive}
                shortcut={{ modifiers: ["ctrl"], key: "x" }}
                onAction={async () => {
                  const toast = await showToast({
                    style: Toast.Style.Animated,
                    title: `Closing PR #${pr.number}…`,
                  });
                  try {
                    // Optimistically drop the PR from the list. GitHub's search
                    // index is eventually consistent, so an immediate revalidate
                    // would re-add the just-closed PR; skip it here and let the
                    // next manual/auto refresh reconcile.
                    await mutate(closePR(pr), {
                      optimisticUpdate: (data) =>
                        data && {
                          ...data,
                          mine: data.mine.filter((p) => p.id !== pr.id),
                          review: data.review.filter((p) => p.id !== pr.id),
                          inProgress: data.inProgress.filter(
                            (p) => p.id !== pr.id,
                          ),
                          merged: data.merged.filter((p) => p.id !== pr.id),
                        },
                      shouldRevalidateAfter: false,
                    });
                    toast.style = Toast.Style.Success;
                    toast.title = `Closed PR #${pr.number}`;
                  } catch (err) {
                    toast.style = Toast.Style.Failure;
                    toast.title = `Failed to close PR #${pr.number}`;
                    toast.message =
                      err instanceof Error ? err.message : String(err);
                  }
                }}
              />
            </ActionPanel.Section>
          )}
          <ActionPanel.Section>
            <Action
              title="Refresh"
              icon={Icon.ArrowClockwise}
              shortcut={{ modifiers: ["cmd"], key: "r" }}
              onAction={revalidate}
            />
            <Action
              title="Configure Repository"
              icon={Icon.Gear}
              shortcut={{ modifiers: ["cmd"], key: "," }}
              onAction={openCommandPreferences}
            />
            <Action
              title="Open Extension Preferences"
              icon={Icon.Gear}
              shortcut={{ modifiers: ["cmd", "shift"], key: "," }}
              onAction={openExtensionPreferences}
            />
          </ActionPanel.Section>
        </ActionPanel>
      }
    />
  );
}

export default function Command() {
  const { repo: rawRepo, excludeRepo: rawExcludeRepo } =
    getPreferenceValues<CommandPrefs>();
  const repos = parseRepoPatterns(rawRepo);
  const excludeRepos = parseRepoPatterns(rawExcludeRepo);
  const [filter, setFilter] = useState<
    "all" | "mine" | "review" | "in-progress" | "merged"
  >("mine");

  const reposKey = repos.join(",");
  const excludeKey = excludeRepos.join(",");
  const { data, isLoading, revalidate, mutate, error } = useCachedPromise(
    async (incKey: string, excKey: string) =>
      fetchPRs(
        incKey ? incKey.split(",") : [],
        excKey ? excKey.split(",") : [],
      ),
    [reposKey, excludeKey],
    {
      keepPreviousData: true,
      onError: (err) => {
        showToast({
          style: Toast.Style.Failure,
          title: "Failed to load PRs",
          message: err.message,
        });
      },
    },
  );

  const mine = data?.mine ?? [];
  const review = data?.review ?? [];
  const inProgress = data?.inProgress ?? [];
  const merged = data?.merged ?? [];
  const accounts = data?.accounts ?? [];
  const accountErrors = data?.errors ?? [];
  const showAccount = accounts.length > 1;

  // Surface per-account fetch failures (e.g. one account lacks repo access)
  // without poisoning the whole result.
  useEffect(() => {
    if (accountErrors.length === 0) return;
    void showToast({
      style: Toast.Style.Failure,
      title: `Some gh accounts failed (${accountErrors.length})`,
      message: accountErrors.join("\n"),
    });
  }, [accountErrors.join("|")]);

  const navigationTitle = (() => {
    const repoPart =
      repos.length === 0
        ? "All Repos"
        : repos.length === 1
          ? repos[0]
          : `${repos.length} repos`;
    const accountPart =
      accounts.length <= 1 ? "" : ` · ${accounts.length} accounts`;
    return `GitHub PRs · ${repoPart}${accountPart}`;
  })();

  const emptyState = useMemo(() => {
    if (error) {
      return (
        <List.EmptyView
          icon={{ source: Icon.ExclamationMark, tintColor: Color.Red }}
          title="Couldn't load PRs"
          description={error.message}
          actions={
            <ActionPanel>
              <Action
                title="Retry"
                icon={Icon.ArrowClockwise}
                onAction={revalidate}
              />
              <Action
                title="Configure Repository"
                icon={Icon.Gear}
                onAction={openCommandPreferences}
              />
              <Action
                title="Open Extension Preferences"
                icon={Icon.Gear}
                onAction={openExtensionPreferences}
              />
            </ActionPanel>
          }
        />
      );
    }
    return (
      <List.EmptyView
        icon={Icon.CheckCircle}
        title={isLoading ? "Loading…" : "No PRs"}
        description={
          isLoading
            ? undefined
            : "Nothing to review and nothing of yours is open. 🎉"
        }
      />
    );
  }, [error, isLoading, revalidate]);

  const showMine = filter === "all" || filter === "mine";
  const showReview = filter === "all" || filter === "review";
  const showInProgress = filter === "all" || filter === "in-progress";
  const showMerged = filter === "merged";

  return (
    <List
      isLoading={isLoading}
      navigationTitle={navigationTitle}
      searchBarPlaceholder="Filter by title, number, author, or repo…"
      searchBarAccessory={
        <List.Dropdown
          tooltip="Filter section"
          value={filter}
          onChange={(v) => setFilter(v as typeof filter)}
        >
          <List.Dropdown.Item
            title="All"
            value="all"
            icon={Icon.AppWindowGrid2x2}
          />
          <List.Dropdown.Item
            title="My Open PRs"
            value="mine"
            icon={Icon.Person}
          />
          <List.Dropdown.Item
            title="Review Requested"
            value="review"
            icon={Icon.Eye}
          />
          <List.Dropdown.Item
            title="Review in Progress"
            value="in-progress"
            icon={Icon.SpeechBubble}
          />
          <List.Dropdown.Item
            title="Merged"
            value="merged"
            icon={Icon.Checkmark}
          />
        </List.Dropdown>
      }
    >
      {showMine && (
        <List.Section title="My Open PRs" subtitle={`${mine.length}`}>
          {mine.map((pr) => (
            <PRListItem
              key={pr.id}
              pr={pr}
              section="mine"
              showAccount={showAccount}
              revalidate={revalidate}
              mutate={mutate}
            />
          ))}
        </List.Section>
      )}
      {showReview && (
        <List.Section title="Review Requested" subtitle={`${review.length}`}>
          {review.map((pr) => (
            <PRListItem
              key={pr.id}
              pr={pr}
              section="review"
              showAccount={showAccount}
              revalidate={revalidate}
              mutate={mutate}
            />
          ))}
        </List.Section>
      )}
      {showInProgress && (
        <List.Section
          title="Review in Progress"
          subtitle={`${inProgress.length}`}
        >
          {inProgress.map((pr) => (
            <PRListItem
              key={`ip-${pr.id}`}
              pr={pr}
              section="in-progress"
              showAccount={showAccount}
              revalidate={revalidate}
              mutate={mutate}
            />
          ))}
        </List.Section>
      )}
      {showMerged && (
        <List.Section title="Merged" subtitle={`${merged.length}`}>
          {merged.map((pr) => (
            <PRListItem
              key={`merged-${pr.id}`}
              pr={pr}
              section="merged"
              showAccount={showAccount}
              revalidate={revalidate}
              mutate={mutate}
            />
          ))}
        </List.Section>
      )}
      {!isLoading &&
        mine.length === 0 &&
        review.length === 0 &&
        inProgress.length === 0 &&
        merged.length === 0 &&
        emptyState}
    </List>
  );
}
