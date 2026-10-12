import { getPreferenceValues } from "@raycast/api";
import { readFileSync } from "node:fs";
import { basename, extname } from "node:path";

export interface SlackProfile {
  status_text: string;
  status_emoji: string;
  status_expiration: number;
}

interface Prefs {
  token: string;
  presetsJSON?: string;
}

function getToken(): string {
  const { token } = getPreferenceValues<Prefs>();
  if (!token || !token.trim()) {
    throw new Error("Slack user token is not configured. Open extension preferences and add an xoxp-… token.");
  }
  return token.trim();
}

async function slackPost<T extends { ok: boolean; error?: string }>(
  endpoint: string,
  body: Record<string, unknown>,
): Promise<T> {
  const res = await fetch(`https://slack.com/api/${endpoint}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${getToken()}`,
      "Content-Type": "application/json; charset=utf-8",
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    throw new Error(`Slack ${endpoint} HTTP ${res.status} ${res.statusText}`);
  }
  const json = (await res.json()) as T;
  if (!json.ok) {
    throw new Error(`Slack ${endpoint} error: ${json.error ?? "unknown"}`);
  }
  return json;
}

async function slackGet<T extends { ok: boolean; error?: string }>(endpoint: string): Promise<T> {
  const res = await fetch(`https://slack.com/api/${endpoint}`, {
    headers: { Authorization: `Bearer ${getToken()}` },
  });
  if (!res.ok) {
    throw new Error(`Slack ${endpoint} HTTP ${res.status} ${res.statusText}`);
  }
  const json = (await res.json()) as T;
  if (!json.ok) {
    throw new Error(`Slack ${endpoint} error: ${json.error ?? "unknown"}`);
  }
  return json;
}

export async function getCurrentStatus(): Promise<SlackProfile> {
  const res = await slackGet<{ ok: boolean; profile: SlackProfile; error?: string }>("users.profile.get");
  return {
    status_text: res.profile.status_text ?? "",
    status_emoji: res.profile.status_emoji ?? "",
    status_expiration: Number(res.profile.status_expiration ?? 0),
  };
}

export async function setStatus(emoji: string, text: string, expirationUnix: number): Promise<void> {
  await slackPost("users.profile.set", {
    profile: {
      status_text: text,
      status_emoji: emoji,
      status_expiration: expirationUnix,
    },
  });
}

export async function clearStatus(): Promise<void> {
  await setStatus("", "", 0);
}

export async function setProfilePhoto(filePath: string): Promise<void> {
  const bytes = new Uint8Array(readFileSync(filePath));
  const ext = extname(filePath).toLowerCase();
  const mime =
    ext === ".jpg" || ext === ".jpeg" ? "image/jpeg" : ext === ".gif" ? "image/gif" : "image/png";

  // Onecast's runtime defines neither FormData nor Blob, and its fetch encodes a body it does not
  // recognise as the string "[object FormData]" — which is why the photo silently never changed.
  // A Uint8Array it does understand, so the multipart envelope is written out by hand.
  const encoder = new TextEncoder();
  const boundary = `----onecast${Date.now().toString(16)}${Math.random().toString(16).slice(2)}`;
  const head = encoder.encode(
    `--${boundary}\r\n` +
      `Content-Disposition: form-data; name="image"; filename="${basename(filePath)}"\r\n` +
      `Content-Type: ${mime}\r\n\r\n`
  );
  const tail = encoder.encode(`\r\n--${boundary}--\r\n`);
  const body = new Uint8Array(head.length + bytes.length + tail.length);
  body.set(head, 0);
  body.set(bytes, head.length);
  body.set(tail, head.length + bytes.length);

  const res = await fetch("https://slack.com/api/users.setPhoto", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${getToken()}`,
      "Content-Type": `multipart/form-data; boundary=${boundary}`,
    },
    body,
  });
  if (!res.ok) {
    throw new Error(`Slack users.setPhoto HTTP ${res.status} ${res.statusText}`);
  }
  const json = (await res.json()) as { ok: boolean; error?: string };
  if (!json.ok) {
    throw new Error(`Slack users.setPhoto error: ${json.error ?? "unknown"}`);
  }
}

/** Convert minutes-from-now into a unix timestamp. 0 means "don't clear". */
export function expirationFromMinutes(minutes: number): number {
  if (!minutes || minutes <= 0) return 0;
  return Math.floor(Date.now() / 1000) + minutes * 60;
}

/**
 * Unix timestamp for the next occurrence of `hour:minute` in India Standard
 * Time (UTC+5:30, no DST). If that wall-clock time has already passed today in
 * IST, the next day's occurrence is returned. Used to auto-clear the On Call
 * status at 8:30 PM IST regardless of the machine's local timezone.
 */
export function expirationAtIst(hour: number, minute: number): number {
  const IST_OFFSET_MS = (5 * 60 + 30) * 60 * 1000;
  const now = Date.now();
  const istNow = new Date(now + IST_OFFSET_MS);
  let targetMs =
    Date.UTC(istNow.getUTCFullYear(), istNow.getUTCMonth(), istNow.getUTCDate(), hour, minute, 0, 0) - IST_OFFSET_MS;
  if (targetMs <= now) targetMs += 24 * 60 * 60 * 1000;
  return Math.floor(targetMs / 1000);
}

export function formatExpiration(unix: number): string {
  if (!unix) return "no expiration";
  const diffSec = unix - Math.floor(Date.now() / 1000);
  if (diffSec <= 0) return "expired";
  const m = Math.round(diffSec / 60);
  if (m < 60) return `${m}m left`;
  const h = Math.floor(m / 60);
  const rem = m % 60;
  return rem === 0 ? `${h}h left` : `${h}h ${rem}m left`;
}
