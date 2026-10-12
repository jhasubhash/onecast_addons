import { Toast, showHUD, showToast } from "@raycast/api";
import { basename } from "node:path";
import { setProfilePhoto } from "./slack";
import { resolveFunPhoto } from "./photos";
import { setPhotoBaseMode } from "./photo-state";

/**
 * Sets the Slack profile picture to a random image from `assets/fun/` and
 * makes Fun the persisted base mode, so it stays in place — the background
 * restore-photo command and status changes both resolve back to it — until
 * "Set Profile Picture: Main" is run instead.
 */
export default async function Command() {
  try {
    const imagePath = resolveFunPhoto();
    await setProfilePhoto(imagePath);
    await setPhotoBaseMode("fun");
    await showHUD(`✅ Slack profile picture set to Fun (${basename(imagePath)})`);
  } catch (e) {
    await showToast({
      style: Toast.Style.Failure,
      title: "Failed to update Slack profile picture",
      message: (e as Error).message,
    });
  }
}
