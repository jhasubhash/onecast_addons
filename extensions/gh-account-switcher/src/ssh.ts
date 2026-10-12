import { readFile, writeFile, mkdir, copyFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { getPreferenceValues } from "@raycast/api";

interface Prefs {
  sshKeyMap?: string;
  sshConfigPath?: string;
}

export interface SshUpdateResult {
  updated: boolean;
  reason?: string;
  identityFile?: string;
  configPath?: string;
}

function expandHome(p: string): string {
  if (p.startsWith("~/")) return join(homedir(), p.slice(2));
  if (p === "~") return homedir();
  return p;
}

/**
 * Parses the sshKeyMap preference. Format: one mapping per line.
 *   host:user=/path/to/key
 * Lines starting with # and blank lines are ignored.
 */
export function parseKeyMap(raw: string | undefined): Map<string, string> {
  const map = new Map<string, string>();
  if (!raw) return map;
  // Allow newline, semicolon, or comma as entry separator so the value can fit
  // in Raycast's single-line preference field.
  for (const rawLine of raw.split(/[\r\n;,]+/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq < 0) continue;
    const key = line.slice(0, eq).trim();
    const value = line.slice(eq + 1).trim();
    if (!key || !value) continue;
    map.set(key.toLowerCase(), expandHome(value));
  }
  return map;
}

export function lookupIdentity(host: string, user: string): string | undefined {
  const { sshKeyMap } = getPreferenceValues<Prefs>();
  const map = parseKeyMap(sshKeyMap);
  return (
    map.get(`${host}:${user}`.toLowerCase()) ??
    map.get(user.toLowerCase())
  );
}

export function getSshConfigPath(): string {
  const { sshConfigPath } = getPreferenceValues<Prefs>();
  const override = sshConfigPath?.trim();
  return override ? expandHome(override) : join(homedir(), ".ssh", "config");
}

/**
 * Rewrites the IdentityFile line inside the `Host <host>` block of ~/.ssh/config.
 * If the block exists but has no IdentityFile, one is inserted. If the block does
 * not exist, a new block is appended. Other host blocks (including aliases that
 * point to the same HostName) are left untouched so users can keep alt configs.
 *
 * A timestamped backup of the original config is written next to it on first edit.
 */
export async function updateSshIdentityFile(host: string, identityFile: string): Promise<SshUpdateResult> {
  const configPath = getSshConfigPath();
  const expandedKey = expandHome(identityFile);

  let original = "";
  if (existsSync(configPath)) {
    original = await readFile(configPath, "utf8");
  } else {
    await mkdir(dirname(configPath), { recursive: true, mode: 0o700 });
  }

  const lines = original.split(/\r?\n/);
  const result: string[] = [];

  // Find the start of the target Host block. We match a literal "Host github.com"
  // (case-insensitive on the directive, exact match on the host token) and ignore
  // host alias entries like `Host github-personal`.
  const hostHeaderRe = /^\s*Host\s+(.+?)\s*$/i;
  const identityRe = /^(\s*)IdentityFile\s+.*$/i;

  let inTargetBlock = false;
  let identityWritten = false;
  let blockFound = false;
  let blockIndent = "    ";

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const headerMatch = line.match(hostHeaderRe);

    if (headerMatch) {
      // Leaving previous target block without writing IdentityFile? Insert it now.
      if (inTargetBlock && !identityWritten) {
        result.push(`${blockIndent}IdentityFile ${expandedKey}`);
        identityWritten = true;
      }
      const tokens = headerMatch[1].split(/\s+/);
      inTargetBlock = tokens.includes(host);
      if (inTargetBlock) {
        blockFound = true;
        identityWritten = false;
      }
      result.push(line);
      continue;
    }

    if (inTargetBlock) {
      const identMatch = line.match(identityRe);
      if (identMatch) {
        if (!identityWritten) {
          blockIndent = identMatch[1] || blockIndent;
          result.push(`${blockIndent}IdentityFile ${expandedKey}`);
          identityWritten = true;
        }
        // Drop any additional IdentityFile lines inside the same block.
        continue;
      }
      // Track indent from any indented directive in the block.
      const indentMatch = line.match(/^(\s+)\S/);
      if (indentMatch) blockIndent = indentMatch[1];
    }

    result.push(line);
  }

  // EOF cleanup: if file ended while still inside the target block without an IdentityFile.
  if (inTargetBlock && !identityWritten) {
    result.push(`${blockIndent}IdentityFile ${expandedKey}`);
    identityWritten = true;
  }

  if (!blockFound) {
    if (result.length && result[result.length - 1].trim() !== "") result.push("");
    result.push(`Host ${host}`);
    result.push(`    HostName ${host}`);
    result.push(`    User git`);
    result.push(`    IdentityFile ${expandedKey}`);
    result.push(`    IdentitiesOnly yes`);
  }

  const updated = result.join("\n");
  if (updated === original) {
    return { updated: false, reason: "ssh config already matches", identityFile: expandedKey, configPath };
  }

  if (existsSync(configPath)) {
    const backup = `${configPath}.bak.${Date.now()}`;
    try {
      await copyFile(configPath, backup);
    } catch {
      // Backup is best-effort; proceed with write.
    }
  }

  await writeFile(configPath, updated, { mode: 0o600 });
  return { updated: true, identityFile: expandedKey, configPath };
}

export async function applySshIdentityForAccount(host: string, user: string): Promise<SshUpdateResult> {
  const identity = lookupIdentity(host, user);
  if (!identity) {
    return { updated: false, reason: "no SSH key mapping configured for this account" };
  }
  if (!existsSync(identity)) {
    return { updated: false, reason: `mapped key not found: ${identity}`, identityFile: identity };
  }
  return updateSshIdentityFile(host, identity);
}
