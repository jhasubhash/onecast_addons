import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { getPreferenceValues } from "@raycast/api";

const execFileAsync = promisify(execFile);

/** The other Mac's SSH destination from the preference, or undefined when it isn't set. */
export function otherMacHost(): string | undefined {
  return getPreferenceValues<{ otherMac?: string }>().otherMac?.trim() || undefined;
}

/**
 * Turn the other Mac's display on by declaring user activity there (`caffeinate -u`). A monitor's
 * built-in KVM hands its USB to a Mac only once that Mac sends it video, and a Mac with its display
 * asleep (lid closed) sends none, so the keyboard falls back to Bluetooth and this Mac keeps it.
 * BatchMode: never prompt from a no-view command; a missing key fails fast instead.
 */
export async function wakeDisplay(host: string): Promise<void> {
  await execFileAsync(
    "/usr/bin/ssh",
    ["-o", "BatchMode=yes", "-o", "ConnectTimeout=3", host, "caffeinate -u -t 1"],
    { timeout: 8_000 },
  );
}
