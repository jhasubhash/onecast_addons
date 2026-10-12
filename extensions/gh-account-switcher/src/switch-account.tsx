import {
  Action,
  ActionPanel,
  Color,
  Icon,
  List,
  Toast,
  showToast,
  openExtensionPreferences,
} from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { listAccounts, switchAccount, GhAccount } from "./gh";
import { applySshIdentityForAccount } from "./ssh";

export default function Command() {
  const { data, isLoading, revalidate, error } = useCachedPromise(listAccounts, [], {
    keepPreviousData: true,
  });

  const accounts = data ?? [];
  const byHost = new Map<string, GhAccount[]>();
  for (const a of accounts) {
    const list = byHost.get(a.host) ?? [];
    list.push(a);
    byHost.set(a.host, list);
  }

  return (
    <List
      isLoading={isLoading}
      searchBarPlaceholder="Filter accounts by user or host…"
    >
      {error ? (
        <List.EmptyView
          icon={Icon.Warning}
          title="Failed to read gh auth status"
          description={String(error)}
          actions={
            <ActionPanel>
              <Action title="Retry" icon={Icon.ArrowClockwise} onAction={() => revalidate()} />
              <Action title="Open Extension Preferences" icon={Icon.Gear} onAction={openExtensionPreferences} />
            </ActionPanel>
          }
        />
      ) : accounts.length === 0 && !isLoading ? (
        <List.EmptyView
          icon={Icon.Person}
          title="No gh accounts found"
          description="Run `gh auth login` in a terminal first."
          actions={
            <ActionPanel>
              <Action title="Retry" icon={Icon.ArrowClockwise} onAction={() => revalidate()} />
            </ActionPanel>
          }
        />
      ) : (
        Array.from(byHost.entries()).map(([host, list]) => (
          <List.Section key={host} title={host} subtitle={`${list.length} account${list.length === 1 ? "" : "s"}`}>
            {list.map((acct) => {
              const isActive = acct.active;
              const accessory: List.Item.Accessory[] = [];
              if (isActive) accessory.push({ tag: { value: "Active", color: Color.Green } });
              if (!acct.valid) accessory.push({ tag: { value: "Invalid token", color: Color.Red } });
              if (acct.protocol) accessory.push({ text: acct.protocol });

              return (
                <List.Item
                  key={`${host}\u0000${acct.user}`}
                  title={acct.user}
                  subtitle={acct.scopes ? `scopes: ${acct.scopes}` : undefined}
                  icon={{
                    source: isActive ? Icon.CheckCircle : Icon.Circle,
                    tintColor: isActive ? Color.Green : acct.valid ? Color.SecondaryText : Color.Red,
                  }}
                  accessories={accessory}
                  actions={
                    <ActionPanel>
                      <Action
                        title={isActive ? "Already Active" : `Switch to ${acct.user}`}
                        icon={Icon.Switch}
                        onAction={async () => {
                          if (isActive) {
                            await showToast({ style: Toast.Style.Success, title: "Already active", message: `${acct.user} on ${host}` });
                            return;
                          }
                          const toast = await showToast({
                            style: Toast.Style.Animated,
                            title: `Switching to ${acct.user}`,
                            message: host,
                          });
                          try {
                            await switchAccount(host, acct.user);
                            const ssh = await applySshIdentityForAccount(host, acct.user);
                            toast.style = Toast.Style.Success;
                            toast.title = "Switched";
                            toast.message = ssh.updated
                              ? `${acct.user} on ${host} · ssh key updated`
                              : ssh.reason
                                ? `${acct.user} on ${host} · ssh: ${ssh.reason}`
                                : `${acct.user} on ${host}`;
                            revalidate();
                          } catch (e) {
                            toast.style = Toast.Style.Failure;
                            toast.title = "Switch failed";
                            toast.message = e instanceof Error ? e.message : String(e);
                          }
                        }}
                      />
                      <Action
                        title="Refresh"
                        icon={Icon.ArrowClockwise}
                        shortcut={{ modifiers: ["cmd"], key: "r" }}
                        onAction={() => revalidate()}
                      />
                      <Action.CopyToClipboard
                        title="Copy User Handle"
                        content={acct.user}
                        shortcut={{ modifiers: ["cmd"], key: "." }}
                      />
                      <Action
                        title="Open Extension Preferences"
                        icon={Icon.Gear}
                        shortcut={{ modifiers: ["cmd"], key: "," }}
                        onAction={openExtensionPreferences}
                      />
                    </ActionPanel>
                  }
                />
              );
            })}
          </List.Section>
        ))
      )}
    </List>
  );
}
