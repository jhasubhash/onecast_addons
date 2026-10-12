import { showHUD, showToast, Toast } from "@raycast/api";
import { getToggleHost, listAccounts, switchAccount } from "./gh";
import { applySshIdentityForAccount } from "./ssh";

export default async function Command() {
  const host = getToggleHost();
  try {
    const accounts = (await listAccounts()).filter((a) => a.host === host);
    if (accounts.length === 0) {
      await showToast({ style: Toast.Style.Failure, title: "No accounts", message: `No gh accounts on ${host}` });
      return;
    }
    if (accounts.length === 1) {
      await showHUD(`Only one account on ${host}: ${accounts[0].user}`);
      return;
    }
    const activeIdx = accounts.findIndex((a) => a.active);
    const next = accounts[(activeIdx + 1) % accounts.length];
    await switchAccount(next.host, next.user);
    const ssh = await applySshIdentityForAccount(next.host, next.user);
    const sshSuffix = ssh.updated ? " · ssh key updated" : "";
    await showHUD(`gh → ${next.user} @ ${next.host}${sshSuffix}`);
  } catch (e) {
    await showToast({
      style: Toast.Style.Failure,
      title: "Toggle failed",
      message: e instanceof Error ? e.message : String(e),
    });
  }
}
