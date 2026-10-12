import {
  Action,
  ActionPanel,
  Color,
  Form,
  Icon,
  LocalStorage,
  List,
  Toast,
  getPreferenceValues,
  openExtensionPreferences,
  showToast,
  useNavigation,
} from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { useEffect, useState } from "react";

interface Prefs {
  baseURL: string;
  token: string;
  defaultJQL?: string;
  maxResults?: string;
}

interface JiraIssue {
  key: string;
  summary: string;
  status: string;
  statusCategory: string;
  issueType: string;
  priority: string;
  updated?: string;
}

type TabId = "assigned" | "reported" | "watching" | "custom";

const TABS: Record<TabId, { title: string; icon: Icon; tint: Color; jql: string }> = {
  assigned: {
    title: "Assigned to me",
    icon: Icon.PersonCircle,
    tint: Color.Blue,
    jql: "assignee = currentUser() ORDER BY updated DESC",
  },
  reported: {
    title: "Reported by me",
    icon: Icon.Pencil,
    tint: Color.Purple,
    jql: "reporter = currentUser() ORDER BY updated DESC",
  },
  watching: {
    title: "Watching",
    icon: Icon.Eye,
    tint: Color.Yellow,
    jql: "watcher = currentUser() ORDER BY updated DESC",
  },
  custom: {
    title: "Custom JQL",
    icon: Icon.Filter,
    tint: Color.Orange,
    jql: "",
  },
};

const CUSTOM_JQL_STORAGE_KEY = "jira.customJQL";

function normaliseBaseURL(url: string): string {
  return url.trim().replace(/\/+$/, "");
}

function buildSearchURL(baseURL: string, jql: string, maxResults: number): string {
  const params = new URLSearchParams({
    jql,
    fields: "summary,status,issuetype,priority,updated",
    maxResults: String(maxResults),
  });
  return `${normaliseBaseURL(baseURL)}/rest/api/2/search?${params.toString()}`;
}

function issueURL(baseURL: string, key: string): string {
  return `${normaliseBaseURL(baseURL)}/browse/${encodeURIComponent(key)}`;
}

interface RawIssue {
  key: string;
  fields?: {
    summary?: string;
    status?: { name?: string; statusCategory?: { name?: string } };
    issuetype?: { name?: string };
    priority?: { name?: string };
    updated?: string;
  };
}

function parseIssue(raw: RawIssue): JiraIssue {
  const f = raw.fields ?? {};
  return {
    key: raw.key,
    summary: f.summary ?? "",
    status: f.status?.name ?? "",
    statusCategory: f.status?.statusCategory?.name ?? "",
    issueType: f.issuetype?.name ?? "",
    priority: f.priority?.name ?? "",
    updated: f.updated,
  };
}

async function fetchIssues(
  baseURL: string,
  token: string,
  jql: string,
  maxResults: number,
): Promise<JiraIssue[]> {
  if (!baseURL || !token) throw new Error("Configure Base URL and API Token in preferences.");
  if (!jql.trim()) throw new Error("JQL is empty.");

  const res = await fetch(buildSearchURL(baseURL, jql, maxResults), {
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/json",
    },
  });

  if (!res.ok) {
    let body = "";
    try {
      body = await res.text();
    } catch {
      // ignore
    }
    const snippet = body.slice(0, 200);
    throw new Error(`HTTP ${res.status} ${res.statusText}${snippet ? ` — ${snippet}` : ""}`);
  }

  const json = (await res.json()) as { issues?: RawIssue[] };
  return (json.issues ?? []).map(parseIssue);
}

function issueTypeIcon(type: string): { source: Icon; tintColor: Color } {
  const t = type.toLowerCase();
  if (t === "bug") return { source: Icon.Bug, tintColor: Color.Red };
  if (t === "story" || t === "user story") return { source: Icon.Bookmark, tintColor: Color.Green };
  if (t === "task") return { source: Icon.CheckCircle, tintColor: Color.Blue };
  if (t === "epic") return { source: Icon.Bolt, tintColor: Color.Purple };
  if (t === "sub-task" || t === "subtask") return { source: Icon.ArrowDown, tintColor: Color.Yellow };
  if (t === "improvement" || t === "new feature") return { source: Icon.Star, tintColor: Color.Yellow };
  return { source: Icon.Circle, tintColor: Color.SecondaryText };
}

function statusTagColor(category: string): Color {
  switch (category.toLowerCase()) {
    case "in progress":
    case "indeterminate":
      return Color.Blue;
    case "done":
      return Color.Green;
    default:
      return Color.SecondaryText;
  }
}

function priorityTag(priority: string): { value: string; color: Color } {
  switch (priority.toLowerCase()) {
    case "blocker":
      return { value: "Blocker", color: Color.Red };
    case "critical":
      return { value: "Critical", color: Color.Orange };
    case "major":
      return { value: "Major", color: Color.Yellow };
    case "minor":
      return { value: "Minor", color: Color.Green };
    case "trivial":
      return { value: "Trivial", color: Color.SecondaryText };
    default:
      return { value: priority || "—", color: Color.SecondaryText };
  }
}

function CustomJQLForm({
  initialJQL,
  onSubmit,
}: {
  initialJQL: string;
  onSubmit: (jql: string) => void;
}) {
  const { pop } = useNavigation();
  return (
    <Form
      navigationTitle="Edit Custom JQL"
      actions={
        <ActionPanel>
          <Action.SubmitForm
            title="Run Query"
            icon={Icon.MagnifyingGlass}
            onSubmit={(values: { jql: string }) => {
              onSubmit(values.jql.trim());
              pop();
            }}
          />
        </ActionPanel>
      }
    >
      <Form.TextArea
        id="jql"
        title="JQL"
        placeholder='project = PS AND status = "In Progress" ORDER BY updated DESC'
        defaultValue={initialJQL}
        autoFocus
        info="Standard Jira JQL. The query runs server-side; the search bar below filters results locally."
      />
    </Form>
  );
}

function CustomEmptyView({
  customJQL,
  onSave,
}: {
  customJQL: string;
  onSave: (jql: string) => void | Promise<void>;
}) {
  const { push } = useNavigation();
  return (
    <List.EmptyView
      icon={{ source: Icon.Filter, tintColor: Color.Orange }}
      title="No Custom JQL set"
      description="Press ⌘E (or Enter) to write a JQL query."
      actions={
        <ActionPanel>
          <Action
            title="Edit Custom JQL"
            icon={Icon.Pencil}
            onAction={() =>
              push(<CustomJQLForm initialJQL={customJQL} onSubmit={(q) => void onSave(q)} />)
            }
          />
          <Action title="Open Extension Preferences" icon={Icon.Gear} onAction={openExtensionPreferences} />
        </ActionPanel>
      }
    />
  );
}

function IssueItem({
  issue,
  baseURL,
  revalidate,
  onEditCustomJQL,
  currentCustomJQL,
}: {
  issue: JiraIssue;
  baseURL: string;
  revalidate: () => void;
  onEditCustomJQL: (jql: string) => void | Promise<void>;
  currentCustomJQL: string;
}) {
  const { push } = useNavigation();
  const url = issueURL(baseURL, issue.key);
  const prio = priorityTag(issue.priority);

  const accessories: List.Item.Accessory[] = [
    { tag: { value: issue.status || "—", color: statusTagColor(issue.statusCategory) } },
    { tag: { value: prio.value, color: prio.color } },
    { text: issue.issueType || "" },
  ];
  if (issue.updated) {
    accessories.push({
      date: new Date(issue.updated),
      tooltip: `Updated ${issue.updated}`,
    });
  }

  return (
    <List.Item
      icon={issueTypeIcon(issue.issueType)}
      title={issue.summary || issue.key}
      subtitle={{ value: issue.key, tooltip: issue.key }}
      keywords={[issue.key, issue.status, issue.issueType, issue.priority]}
      accessories={accessories}
      actions={
        <ActionPanel>
          <Action.OpenInBrowser url={url} title="Open Issue in Browser" />
          <Action.CopyToClipboard
            title="Copy Issue URL"
            content={url}
            shortcut={{ modifiers: ["cmd"], key: "u" }}
          />
          <Action.CopyToClipboard
            title="Copy Issue Key"
            content={issue.key}
            shortcut={{ modifiers: ["cmd"], key: "k" }}
          />
          <Action.CopyToClipboard
            title="Copy Title"
            content={`${issue.key}: ${issue.summary}`}
            shortcut={{ modifiers: ["cmd", "shift"], key: "t" }}
          />
          <ActionPanel.Section>
            <Action
              title="Refresh"
              icon={Icon.ArrowClockwise}
              shortcut={{ modifiers: ["cmd"], key: "r" }}
              onAction={revalidate}
            />
            <Action
              title="Edit Custom JQL"
              icon={Icon.Pencil}
              shortcut={{ modifiers: ["cmd"], key: "e" }}
              onAction={() =>
                push(
                  <CustomJQLForm
                    initialJQL={currentCustomJQL}
                    onSubmit={(q) => void onEditCustomJQL(q)}
                  />,
                )
              }
            />
            <Action
              title="Open Extension Preferences"
              icon={Icon.Gear}
              shortcut={{ modifiers: ["cmd"], key: "," }}
              onAction={openExtensionPreferences}
            />
          </ActionPanel.Section>
        </ActionPanel>
      }
    />
  );
}

export default function Command() {
  const prefs = getPreferenceValues<Prefs>();
  const baseURL = (prefs.baseURL ?? "").trim();
  const token = (prefs.token ?? "").trim();
  const maxResults = Math.min(200, Math.max(1, Number.parseInt(prefs.maxResults ?? "50", 10) || 50));

  const [tab, setTab] = useState<TabId>("assigned");
  const [customJQL, setCustomJQL] = useState<string>("");
  const [customJQLLoaded, setCustomJQLLoaded] = useState(false);

  useEffect(() => {
    (async () => {
      const stored = (await LocalStorage.getItem<string>(CUSTOM_JQL_STORAGE_KEY)) ?? "";
      setCustomJQL(stored || prefs.defaultJQL || "");
      setCustomJQLLoaded(true);
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const activeJQL = tab === "custom" ? customJQL : TABS[tab].jql;
  const canQuery =
    baseURL.length > 0 &&
    token.length > 0 &&
    activeJQL.trim().length > 0 &&
    (tab !== "custom" || customJQLLoaded);

  const { data, isLoading, revalidate, error } = useCachedPromise(
    async (b: string, t: string, jql: string, mx: number) => fetchIssues(b, t, jql, mx),
    [baseURL, token, activeJQL, maxResults],
    {
      execute: canQuery,
      keepPreviousData: true,
      onError: (err) => {
        showToast({ style: Toast.Style.Failure, title: "Failed to load issues", message: err.message });
      },
    },
  );

  const issues = data ?? [];
  const tabMeta = TABS[tab];

  return (
    <List
      isLoading={isLoading}
      navigationTitle={`Jira · ${tabMeta.title}`}
      searchBarPlaceholder="Filter by key, summary, status, or type…"
      searchBarAccessory={
        <List.Dropdown tooltip="Tab" value={tab} onChange={(v) => setTab(v as TabId)} storeValue>
          {(Object.keys(TABS) as TabId[]).map((id) => (
            <List.Dropdown.Item
              key={id}
              title={TABS[id].title}
              value={id}
              icon={{ source: TABS[id].icon, tintColor: TABS[id].tint }}
            />
          ))}
        </List.Dropdown>
      }
    >
      {!baseURL || !token ? (
        <List.EmptyView
          icon={{ source: Icon.Gear, tintColor: Color.Orange }}
          title="Configure Jira connection"
          description="Set Base URL and API Token in extension preferences."
          actions={
            <ActionPanel>
              <Action title="Open Extension Preferences" icon={Icon.Gear} onAction={openExtensionPreferences} />
            </ActionPanel>
          }
        />
      ) : tab === "custom" && !customJQL.trim() ? (
        <CustomEmptyView
          customJQL={customJQL}
          onSave={async (q) => {
            setCustomJQL(q);
            await LocalStorage.setItem(CUSTOM_JQL_STORAGE_KEY, q);
          }}
        />
      ) : error && issues.length === 0 ? (
        <List.EmptyView
          icon={{ source: Icon.ExclamationMark, tintColor: Color.Red }}
          title="Couldn't load issues"
          description={error.message}
          actions={
            <ActionPanel>
              <Action title="Retry" icon={Icon.ArrowClockwise} onAction={revalidate} />
              <Action title="Open Extension Preferences" icon={Icon.Gear} onAction={openExtensionPreferences} />
            </ActionPanel>
          }
        />
      ) : (
        <List.Section
          title={tabMeta.title}
          subtitle={issues.length > 0 ? `${issues.length}` : undefined}
        >
          {issues.map((issue) => (
            <IssueItem
              key={issue.key}
              issue={issue}
              baseURL={baseURL}
              revalidate={revalidate}
              onEditCustomJQL={async (q) => {
                setCustomJQL(q);
                await LocalStorage.setItem(CUSTOM_JQL_STORAGE_KEY, q);
                setTab("custom");
              }}
              currentCustomJQL={customJQL}
            />
          ))}
        </List.Section>
      )}
    </List>
  );
}
