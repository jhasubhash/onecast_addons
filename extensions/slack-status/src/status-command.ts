import { closeMainWindow, showHUD } from "@raycast/api";
import { expirationFromMinutes, setStatus } from "./slack";
import { syncProfilePhoto } from "./actions";
import { durationLabel } from "./presets";

/**
 * Build a no-view Raycast command that applies a fixed preset status. It
 * dismisses Raycast immediately, applies the (fast) status change, confirms via
 * HUD, then uploads the synced profile photo in the background so the slower
 * photo call never delays the UI.
 */
export function makeStatusCommand(emoji: string, text: string, minutes: number) {
  return async function Command() {
    await closeMainWindow({ clearRootSearch: true });
    try {
      await setStatus(emoji, text, expirationFromMinutes(minutes));
      const suffix = minutes > 0 ? ` (${durationLabel(minutes)})` : "";
      await showHUD(`✅ Status set: ${text}${suffix}`);
      await syncProfilePhoto(emoji, text);
    } catch (e) {
      await showHUD(`❌ Failed to set status: ${(e as Error).message}`);
    }
  };
}

/**
 * Like {@link makeStatusCommand} but the status expires at an absolute time
 * rather than a fixed number of minutes from now. `expirationUnix` is evaluated
 * when the command runs (e.g. "next 8:30 PM IST"), and `label` describes that
 * expiry in the confirmation HUD. Slack clears the status text/emoji server-side
 * at the expiration; the background restore-photo command puts the normal photo
 * back afterward.
 */
export function makeExpiringStatusCommand(emoji: string, text: string, expirationUnix: () => number, label: string) {
  return async function Command() {
    await closeMainWindow({ clearRootSearch: true });
    try {
      await setStatus(emoji, text, expirationUnix());
      await showHUD(`✅ Status set: ${text} (${label})`);
      await syncProfilePhoto(emoji, text);
    } catch (e) {
      await showHUD(`❌ Failed to set status: ${(e as Error).message}`);
    }
  };
}
