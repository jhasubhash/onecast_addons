import { showHUD, showToast, Toast } from "@raycast/api";
import { listAccounts } from "./gh";

export default async function Command() {
  try {
    const accounts = await listAccounts();
    const active = accounts.filter((a) => a.active);
    if (active.length === 0) {
      await showHUD("No active gh account");
      return;
    }
    const summary = active.map((a) => `${a.user}@${a.host}${a.valid ? "" : " (invalid)"}`).join("  •  ");
    await showHUD(`gh: ${summary}`);
  } catch (e) {
    await showToast({
      style: Toast.Style.Failure,
      title: "Failed",
      message: e instanceof Error ? e.message : String(e),
    });
  }
}
