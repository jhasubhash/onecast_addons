import { Toast, showHUD, showToast } from "@raycast/api";
import { basename } from "node:path";
import { setProfilePhoto } from "./slack";
import { resolveMainPhoto } from "./photos";
import { setPhotoBaseMode } from "./photo-state";

/**
 * Sets the Slack profile picture to a random image from `assets/main/` and
 * makes Main the persisted base mode, so it stays in place — the background
 * restore-photo command and status changes both resolve back to it — until
 * "Set Profile Picture: Fun" is run instead.
 */
export default async function Command() {
  try {
    const imagePath = resolveMainPhoto();
    await setProfilePhoto(imagePath);
    await setPhotoBaseMode("main");
    await showHUD(`✅ Slack profile picture set to Main (${basename(imagePath)})`);
  } catch (e) {
    await showToast({
      style: Toast.Style.Failure,
      title: "Failed to update Slack profile picture",
      message: (e as Error).message,
    });
  }
}
