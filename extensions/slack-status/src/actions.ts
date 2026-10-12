import { setProfilePhoto } from "./slack";
import {
  isLunchStatus,
  isOnCallStatus,
  isPhotoSyncEnabled,
  isPtoStatus,
  isSickStatus,
  resolveDayPhoto,
  resolveLunchPhoto,
  resolveOnCallPhoto,
  resolvePtoPhoto,
  resolveSickPhoto,
} from "./photos";
import { setSpecialPhotoActive } from "./photo-state";

/**
 * Keep the Slack profile photo in sync with the status: lunch, PTO, and
 * out-sick statuses each get a random photo from their dedicated set, and
 * anything else restores the day-of-week photo. Gated on the "Sync profile
 * photo with status" preference. Photo failures are intentionally swallowed so
 * they never block the status change.
 */
export async function syncProfilePhoto(emoji: string, text: string): Promise<void> {
  if (!isPhotoSyncEnabled()) return;
  try {
    let path: string;
    let special = false;
    if (isLunchStatus(emoji, text)) {
      path = resolveLunchPhoto();
      special = true;
    } else if (isPtoStatus(emoji, text)) {
      path = resolvePtoPhoto();
      special = true;
    } else if (isSickStatus(emoji, text)) {
      path = resolveSickPhoto();
      special = true;
    } else if (isOnCallStatus(emoji, text)) {
      path = resolveOnCallPhoto();
      special = true;
    } else {
      path = await resolveDayPhoto();
    }
    await setProfilePhoto(path);
    // Record whether a special photo is active so the background restore
    // command knows to put the normal photo back once the status expires.
    await setSpecialPhotoActive(special);
  } catch {
    // Non-fatal: the status update already succeeded.
  }
}
