import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { promisify } from "node:util";
import { getPreferenceValues } from "@raycast/api";

const execFileAsync = promisify(execFile);

const M1DDC_CANDIDATE_PATHS = ["/opt/homebrew/bin/m1ddc", "/usr/local/bin/m1ddc"];

interface Prefs {
  inputs?: string;
  m1ddcPath?: string;
}

/** A monitor from the preference: a name to match and the input code of each Mac. */
export interface MonitorConfig {
  name: string;
  codes: [number, number];
}

/** A monitor m1ddc can see right now. */
export interface Display {
  index: number;
  name: string;
}

export function resolveM1ddcPath(): string {
  const override = getPreferenceValues<Prefs>().m1ddcPath?.trim();
  if (override && existsSync(override)) return override;
  const found = M1DDC_CANDIDATE_PATHS.find((p) => existsSync(p));
  if (!found) throw new Error("m1ddc not found. Install via: brew install m1ddc");
  return found;
}

async function m1ddc(args: string[]): Promise<string> {
  const { stdout } = await execFileAsync(resolveM1ddcPath(), args, { timeout: 10_000 });
  return stdout.trim();
}

/**
 * Parses the inputs preference, e.g. "BenQ=15/19; LU28R55=17/18".
 * Entries are separated by ';', ',' or newlines so the value fits a single-line field.
 */
export function parseInputs(raw: string | undefined): MonitorConfig[] {
  const monitors: MonitorConfig[] = [];
  for (const entry of (raw ?? "").split(/[\r\n;,]+/)) {
    const match = entry.trim().match(/^(.+?)\s*=\s*(\d+)\s*\/\s*(\d+)$/);
    if (!match) {
      if (entry.trim()) throw new Error(`Bad Monitor Inputs entry "${entry.trim()}", expected name=A/B`);
      continue;
    }
    monitors.push({ name: match[1], codes: [Number(match[2]), Number(match[3])] });
  }
  if (monitors.length === 0) throw new Error("No monitors configured in Monitor Inputs");
  return monitors;
}

export function getMonitorConfigs(): MonitorConfig[] {
  return parseInputs(getPreferenceValues<Prefs>().inputs);
}

/** Lines look like "[1] BenQ PD3205UA (EDCAED26-F2A1-4EB7-B747-03AE3A29E224)". */
export async function listDisplays(): Promise<Display[]> {
  const displays: Display[] = [];
  for (const line of (await m1ddc(["display", "list"])).split(/\r?\n/)) {
    const match = line.match(/^\[(\d+)\]\s+(.*?)\s*(?:\([0-9A-F-]+\))?$/i);
    if (match) displays.push({ index: Number(match[1]), name: match[2] });
  }
  return displays;
}

export async function getInput(display: Display): Promise<number | undefined> {
  try {
    const value = Number(await m1ddc(["display", String(display.index), "get", "input"]));
    return Number.isFinite(value) ? value : undefined;
  } catch {
    return undefined;
  }
}

export async function setInput(display: Display, code: number): Promise<void> {
  await m1ddc(["display", String(display.index), "set", "input", String(code)]);
}
