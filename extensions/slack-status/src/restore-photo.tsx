import { showHUD } from "@raycast/api";
import { getCurrentStatus, setProfilePhoto } from "./slack";
import {
  isLunchStatus,
  isOnCallStatus,
  isPhotoSyncEnabled,
  isPtoStatus,
  isSickStatus,
  resolveDayPhoto,
} from "./photos";
import {
  isRestorePhotoErrorNotified,
  isSpecialPhotoActive,
  setRestorePhotoErrorNotified,
  setSpecialPhotoActive,
} from "./photo-state";

/**
 * Background command: restores the day-of-week profile photo once a
 * Lunch/PTO/Sick status has expired.
 *
 * Slack clears the status text/emoji server-side when its native expiration is
 * reached, but nothing restores the matching profile photo — the status
 * commands are one-shot, so the special photo would linger until Clear Status
 * is run manually. This runs on an interval and only touches Slack while a
 * special photo is actually active (tracked in LocalStorage), so it does no
 * work the rest of the day.
 *
 * Runs unattended every 1 minute, so a persistent failure (most commonly a
 * missing/revoked Slack token) must not fail silently: the first failed run
 * shows an error HUD, and repeats are suppressed until a run succeeds again so
 * a broken token doesn't HUD-spam every minute.
 */
export default async function Command() {
  if (!isPhotoSyncEnabled()) return;
  // Nothing to restore unless a special (lunch/pto/sick) photo is currently set.
  if (!(await isSpecialPhotoActive())) return;

  try {
    const status = await getCurrentStatus();
    const stillSpecial =
      isLunchStatus(status.status_emoji, status.status_text) ||
      isPtoStatus(status.status_emoji, status.status_text) ||
      isSickStatus(status.status_emoji, status.status_text) ||
      isOnCallStatus(status.status_emoji, status.status_text);

    // Status is still lunch/pto/sick: leave the special photo in place.
    if (!stillSpecial) {
      // Status expired or changed away from a special one: put the normal photo back.
      await setProfilePhoto(await resolveDayPhoto());
      await setSpecialPhotoActive(false);
    }
    await setRestorePhotoErrorNotified(false);
  } catch (e) {
    if (!(await isRestorePhotoErrorNotified())) {
      await setRestorePhotoErrorNotified(true);
      await showHUD(`❌ Restore Slack photo failed: ${(e as Error).message}`);
    }
  }
}
