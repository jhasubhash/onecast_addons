import { LocalStorage } from "@raycast/api";

/**
 * Persists whether the Slack profile photo is currently set to a "special"
 * (lunch / PTO / sick) image. Set when {@link syncProfilePhoto} applies one of
 * those photos and cleared once the day-of-week photo is restored. The
 * background `restore-photo` command uses this flag to know when it needs to
 * poll Slack and, after the status expires, put the normal photo back.
 */
const KEY = "specialPhotoActive";

export async function setSpecialPhotoActive(active: boolean): Promise<void> {
  if (active) {
    await LocalStorage.setItem(KEY, "1");
  } else {
    await LocalStorage.removeItem(KEY);
  }
}

export async function isSpecialPhotoActive(): Promise<boolean> {
  return (await LocalStorage.getItem<string>(KEY)) === "1";
}

/**
 * Tracks whether the background `restore-photo` command's last run already surfaced a failure via
 * HUD, so a persistent error (most commonly a missing/revoked Slack token) doesn't re-alert on
 * every 1-minute interval tick — only on the first failure and again after it flips back to ok.
 */
const ERROR_NOTIFIED_KEY = "restorePhotoErrorNotified";

export async function setRestorePhotoErrorNotified(notified: boolean): Promise<void> {
  if (notified) {
    await LocalStorage.setItem(ERROR_NOTIFIED_KEY, "1");
  } else {
    await LocalStorage.removeItem(ERROR_NOTIFIED_KEY);
  }
}

export async function isRestorePhotoErrorNotified(): Promise<boolean> {
  return (await LocalStorage.getItem<string>(ERROR_NOTIFIED_KEY)) === "1";
}

/**
 * Which folder the "steady state" profile photo comes from once no special
 * (lunch/PTO/sick/on-call) status is active. Set by the "Set Profile Picture:
 * Main" / "Set Profile Picture: Fun" commands; read back by
 * `resolveDayPhoto` in `photos.ts` so the choice persists across status
 * changes, the background `restore-photo` command, and app restarts.
 */
const BASE_MODE_KEY = "profilePhotoBaseMode";

export type PhotoBaseMode = "main" | "fun";

export async function setPhotoBaseMode(mode: PhotoBaseMode): Promise<void> {
  // "main" is the default, so storing nothing for it keeps LocalStorage empty
  // for anyone who never runs "Set Profile Picture: Fun".
  if (mode === "main") {
    await LocalStorage.removeItem(BASE_MODE_KEY);
  } else {
    await LocalStorage.setItem(BASE_MODE_KEY, mode);
  }
}

export async function getPhotoBaseMode(): Promise<PhotoBaseMode> {
  return (await LocalStorage.getItem<string>(BASE_MODE_KEY)) === "fun" ? "fun" : "main";
}
