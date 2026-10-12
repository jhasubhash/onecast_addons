import {
  Action,
  ActionPanel,
  Color,
  Icon,
  Image,
  LaunchProps,
  List,
  Toast,
  getPreferenceValues,
  openExtensionPreferences,
  showToast,
} from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { useState } from "react";
import { NewsArticle, parseGoogleNewsRSS } from "./rss";
import { logoURLs } from "./source-logos";

interface Prefs {
  region?: string;
  maxResults?: string;
  showThumbnails?: boolean;
}

const USER_AGENT =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36";

function buildFeedURL(query: string, region: string): string {
  // region looks like "US:en"
  const [gl, hl] = region.split(":");
  const params = new URLSearchParams({
    q: query,
    hl: `${hl ?? "en"}-${gl ?? "US"}`,
    gl: gl ?? "US",
    ceid: `${gl ?? "US"}:${hl ?? "en"}`,
  });
  return `https://news.google.com/rss/search?${params.toString()}`;
}

async function fetchArticles(query: string, region: string, max: number): Promise<NewsArticle[]> {
  if (!query.trim()) return [];
  const res = await fetch(buildFeedURL(query, region), {
    headers: { "User-Agent": USER_AGENT, Accept: "application/rss+xml, application/xml, text/xml" },
  });
  if (!res.ok) {
    throw new Error(`HTTP ${res.status} ${res.statusText}`);
  }
  const xml = await res.text();
  return parseGoogleNewsRSS(xml, max);
}

function articleIcon(article: NewsArticle, showThumbnails: boolean): Image.ImageLike {
  if (!showThumbnails) {
    return { source: Icon.Document, tintColor: Color.SecondaryText };
  }
  const { primary, fallback } = logoURLs(article.sourceName);
  if (primary) {
    return {
      source: primary,
      fallback: fallback ?? Icon.Document,
      mask: Image.Mask.RoundedRectangle,
    };
  }
  return { source: Icon.Document, tintColor: Color.SecondaryText };
}

function relativeTime(date: Date | null): string {
  if (!date) return "";
  const secs = Math.floor((Date.now() - date.getTime()) / 1000);
  if (secs < 60) return "just now";
  if (secs < 3600) return `${Math.floor(secs / 60)}m ago`;
  if (secs < 86400) return `${Math.floor(secs / 3600)}h ago`;
  return `${Math.floor(secs / 86400)}d ago`;
}

export default function Command(
  props: LaunchProps<{ arguments: { query?: string } }>,
) {
  const prefs = getPreferenceValues<Prefs>();
  const region = (prefs.region ?? "US:en").trim() || "US:en";
  const max = Math.min(50, Math.max(1, Number.parseInt(prefs.maxResults ?? "25", 10) || 25));
  const showThumbnails = prefs.showThumbnails ?? true;

  // Seed the search bar from either the command argument (when invoked with
  // an argument) or `fallbackText` (when invoked as a Fallback Command from
  // Raycast's root search).
  const initialQuery = (props.arguments?.query ?? props.fallbackText ?? "").trim();
  const [query, setQuery] = useState(initialQuery);
  const trimmed = query.trim();

  const { data, isLoading, error, revalidate } = useCachedPromise(
    async (q: string, r: string, m: number) => fetchArticles(q, r, m),
    [trimmed, region, max],
    {
      execute: trimmed.length > 0,
      keepPreviousData: true,
      onError: (err) => {
        showToast({ style: Toast.Style.Failure, title: "Failed to load news", message: err.message });
      },
    },
  );

  const articles = data ?? [];

  return (
    <List
      isLoading={isLoading}
      searchBarPlaceholder="Search news…"
      searchText={query}
      throttle
      onSearchTextChange={setQuery}
      navigationTitle="News Search"
    >
      {trimmed.length === 0 ? (
        <List.EmptyView
          icon={{ source: Icon.MagnifyingGlass, tintColor: Color.SecondaryText }}
          title="Start typing to search"
          description="Search top news articles from Google News."
        />
      ) : error && articles.length === 0 ? (
        <List.EmptyView
          icon={{ source: Icon.ExclamationMark, tintColor: Color.Red }}
          title="Couldn't load news"
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
          title={`Results for "${trimmed}"`}
          subtitle={articles.length ? `${articles.length}` : undefined}
        >
          {articles.map((a) => (
            <ArticleRow key={a.id} article={a} showThumbnails={showThumbnails} revalidate={revalidate} />
          ))}
        </List.Section>
      )}
    </List>
  );
}

function ArticleRow({
  article,
  showThumbnails,
  revalidate,
}: {
  article: NewsArticle;
  showThumbnails: boolean;
  revalidate: () => void;
}) {
  const accessories: List.Item.Accessory[] = [];
  if (article.sourceName) {
    accessories.push({ tag: { value: article.sourceName, color: Color.Blue } });
  }
  if (article.publishedAt) {
    accessories.push({
      date: article.publishedAt,
      tooltip: `Published ${article.publishedAt.toLocaleString()} (${relativeTime(article.publishedAt)})`,
    });
  }

  return (
    <List.Item
      icon={articleIcon(article, showThumbnails)}
      title={article.title}
      keywords={[article.sourceName]}
      accessories={accessories}
      actions={
        <ActionPanel>
          <Action.OpenInBrowser url={article.url} title="Open Article" />
          <Action.CopyToClipboard
            title="Copy URL"
            content={article.url}
            shortcut={{ modifiers: ["cmd"], key: "c" }}
          />
          <Action.CopyToClipboard
            title="Copy Title"
            content={article.title}
            shortcut={{ modifiers: ["cmd", "shift"], key: "c" }}
          />
          <Action.CopyToClipboard
            title="Copy Markdown Link"
            content={`[${article.title}](${article.url})`}
            shortcut={{ modifiers: ["cmd", "shift"], key: "m" }}
          />
          <ActionPanel.Section>
            <Action
              title="Refresh"
              icon={Icon.ArrowClockwise}
              shortcut={{ modifiers: ["cmd"], key: "r" }}
              onAction={revalidate}
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
