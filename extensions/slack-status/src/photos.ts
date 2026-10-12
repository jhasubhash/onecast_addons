import { environment, getPreferenceValues } from "@raycast/api";
import { readdirSync } from "node:fs";
import { join } from "node:path";
import { getPhotoBaseMode } from "./photo-state";

/** Whether the "Sync profile photo with status" preference is enabled (defaults to true). */
export function isPhotoSyncEnabled(): boolean {
  return getPreferenceValues<{ syncProfilePhoto?: boolean }>().syncProfilePhoto ?? true;
}

export const DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"] as const;

/**
 * When true, the day-of-week profile photo rotation is paused and the
 * persisted base mode (Main by default, or Fun — see {@link getPhotoBaseMode})
 * is used instead. Flip this to `false` to restore the random per-day photos.
 */
const USE_BASE_PHOTO = true;

const IMAGE_EXT = "(png|jpe?g|webp)";

function pickRandom<T>(items: T[]): T {
  return items[Math.floor(Math.random() * items.length)];
}

/** List files in an assets subfolder matching `^<prefix>-<n>.<ext>$` (case-insensitive). */
function listIndexedImages(subdir: string, prefix: string): string[] {
  const dir = join(environment.assetsPath, subdir);
  // `prefix` is a fixed, code-controlled literal (e.g. a weekday name or "lunch"),
  // never user input, so building this RegExp is safe.
  const pattern = new RegExp(`^${prefix}-\\d+\\.${IMAGE_EXT}$`, "i");
  return readdirSync(dir)
    .filter((f) => pattern.test(f))
    .map((f) => join(dir, f));
}

/**
 * Resolve today's profile photo. When {@link USE_BASE_PHOTO} is enabled this
 * returns a random photo from whichever base mode is persisted — Main by
 * default, or Fun once "Set Profile Picture: Fun" has run; otherwise it picks
 * a random photo for today's weekday from `assets/days/<Day>-<n>.png`.
 */
export async function resolveDayPhoto(): Promise<string> {
  if (USE_BASE_PHOTO) {
    const mode = await getPhotoBaseMode();
    return mode === "fun" ? resolveFunPhoto() : resolveMainPhoto();
  }
  const day = DAYS[new Date().getDay()];
  const candidates = listIndexedImages("days", day);
  if (candidates.length === 0) {
    throw new Error(`No images found for ${day} in assets/days (expected ${day}-0.png, ${day}-1.png, …)`);
  }
  return pickRandom(candidates);
}

/** Pick a random profile photo from a `assets/<folder>/<folder>-<n>.png` set. */
function resolveSetPhoto(folder: string): string {
  const candidates = listIndexedImages(folder, folder);
  if (candidates.length === 0) {
    throw new Error(`No images found in assets/${folder} (expected ${folder}-0.png, ${folder}-1.png, …)`);
  }
  return pickRandom(candidates);
}

/** Pick a random main profile photo from `assets/main/main-<n>.png`. */
export function resolveMainPhoto(): string {
  return resolveSetPhoto("main");
}

/** Pick a random fun profile photo from `assets/fun/fun-<n>.png`. */
export function resolveFunPhoto(): string {
  return resolveSetPhoto("fun");
}

/** Pick a random lunch profile photo from `assets/lunch/lunch-<n>.png`. */
export function resolveLunchPhoto(): string {
  return resolveSetPhoto("lunch");
}

/** Pick a random PTO profile photo from `assets/pto/pto-<n>.png`. */
export function resolvePtoPhoto(): string {
  return resolveSetPhoto("pto");
}

/** Pick a random out-sick profile photo from `assets/sick/sick-<n>.png`. */
export function resolveSickPhoto(): string {
  return resolveSetPhoto("sick");
}

/** Pick a random on-call profile photo from `assets/oncall/oncall-<n>.png`. */
export function resolveOnCallPhoto(): string {
  return resolveSetPhoto("oncall");
}

/** Whether a status should map to the lunch profile photo set. */
export function isLunchStatus(emoji: string, text: string): boolean {
  return text.toLowerCase().includes("lunch") || emoji.toLowerCase() === ":hamburger:";
}

/** Whether a status should map to the PTO profile photo set. */
export function isPtoStatus(emoji: string, text: string): boolean {
  return text.toLowerCase().includes("pto") || emoji.toLowerCase() === ":red_circle:";
}

/** Whether a status should map to the out-sick profile photo set. */
export function isSickStatus(emoji: string, text: string): boolean {
  return text.toLowerCase().includes("sick") || emoji.toLowerCase() === ":face_with_thermometer:";
}

/** Whether a status should map to the on-call profile photo set. */
export function isOnCallStatus(emoji: string, text: string): boolean {
  return text.toLowerCase().includes("on call") || emoji.toLowerCase() === ":telephone_receiver:";
}
