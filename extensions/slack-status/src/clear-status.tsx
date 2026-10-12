import { Toast, showHUD, showToast } from "@raycast/api";
import { clearStatus, setProfilePhoto } from "./slack";
import { isPhotoSyncEnabled, resolveDayPhoto } from "./photos";
import { setSpecialPhotoActive } from "./photo-state";

export default async function Command() {
  try {
    await clearStatus();
    // Confirm + dismiss immediately, then restore the day-of-week profile photo
    // in the background so the slower upload never delays the UI.
    await showHUD("✅ Slack status cleared");
    if (isPhotoSyncEnabled()) {
      try {
        await setProfilePhoto(await resolveDayPhoto());
        await setSpecialPhotoActive(false);
      } catch {
        /* ignore photo restore failures */
      }
    }
  } catch (e) {
    await showToast({
      style: Toast.Style.Failure,
      title: "Failed to clear Slack status",
      message: (e as Error).message,
    });
  }
}
