import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { promisify } from "node:util";
import { getPreferenceValues } from "@raycast/api";

const execFileAsync = promisify(execFile);

const GH_CANDIDATE_PATHS = [
  "/opt/homebrew/bin/gh",
  "/usr/local/bin/gh",
  "/opt/homebrew/sbin/gh",
  "/usr/bin/gh",
];

interface Prefs {
  ghPath?: string;
  toggleHost?: string;
}

export function resolveGhPath(): string {
  const ext = getPreferenceValues<Prefs>();
  const override = ext.ghPath?.trim();
  if (override && existsSync(override)) return override;
  const found = GH_CANDIDATE_PATHS.find((p) => existsSync(p));
  if (!found) throw new Error("gh CLI not found. Install via: brew install gh");
  return found;
}

export function getToggleHost(): string {
  const ext = getPreferenceValues<Prefs>();
  return ext.toggleHost?.trim() || "github.com";
}

function ghEnv() {
  return {
    ...process.env,
    PATH: `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${process.env.PATH ?? ""}`,
  };
}

export async function gh(args: string[]): Promise<{ stdout: string; stderr: string }> {
  const bin = resolveGhPath();
  const { stdout, stderr } = await execFileAsync(bin, args, {
    env: ghEnv(),
    maxBuffer: 1024 * 1024,
  });
  return { stdout, stderr };
}

export interface GhAccount {
  host: string;
  user: string;
  active: boolean;
  valid: boolean;
  scopes?: string;
  protocol?: string;
  statusLine?: string;
}

/**
 * Parses `gh auth status` output across hosts and accounts.
 * gh writes the structured status to stderr; format is stable enough to parse line-by-line.
 */
export async function listAccounts(): Promise<GhAccount[]> {
  let raw = "";
  try {
    const { stdout, stderr } = await execFileAsync(resolveGhPath(), ["auth", "status"], {
      env: ghEnv(),
      maxBuffer: 1024 * 1024,
    });
    raw = `${stderr}\n${stdout}`;
  } catch (err: unknown) {
    // gh exits non-zero if any host has an invalid token, but still prints status to stderr.
    const e = err as { stdout?: string; stderr?: string };
    raw = `${e.stderr ?? ""}\n${e.stdout ?? ""}`;
    if (!raw.trim()) throw err;
  }

  const accounts: GhAccount[] = [];
  let currentHost = "";
  let current: GhAccount | null = null;

  const flush = () => {
    if (current) accounts.push(current);
    current = null;
  };

  for (const rawLine of raw.split(/\r?\n/)) {
    const line = rawLine.replace(/\s+$/g, "");
    if (!line.trim()) continue;

    // Host header lines have no leading whitespace and look like "github.com" or "git.example.com"
    if (/^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/.test(line.trim()) && !line.startsWith(" ")) {
      flush();
      currentHost = line.trim();
      continue;
    }

    // Account header: "  ✓ Logged in to <host> account <user> (<source>)"
    //                  or "  X Failed to log in to <host> account <user> (<source>)"
    const acctMatch = line.match(/^\s*(✓|X|x|!)\s+(?:Logged in to|Failed to log in to)\s+([^\s]+)\s+account\s+([^\s(]+)/);
    if (acctMatch) {
      flush();
      current = {
        host: acctMatch[2] || currentHost,
        user: acctMatch[3],
        active: false,
        valid: acctMatch[1] === "✓",
        statusLine: line.trim(),
      };
      continue;
    }

    if (!current) continue;

    const activeMatch = line.match(/Active account:\s*(true|false)/i);
    if (activeMatch) {
      current.active = activeMatch[1].toLowerCase() === "true";
      continue;
    }
    const scopeMatch = line.match(/Token scopes:\s*(.+)$/);
    if (scopeMatch) {
      current.scopes = scopeMatch[1].replace(/['"]/g, "");
      continue;
    }
    const protoMatch = line.match(/Git operations protocol:\s*(.+)$/);
    if (protoMatch) {
      current.protocol = protoMatch[1].trim();
      continue;
    }
  }
  flush();

  return accounts;
}

export async function switchAccount(host: string, user: string): Promise<void> {
  await gh(["auth", "switch", "--hostname", host, "--user", user]);
}
