export interface NewsArticle {
  id: string;
  title: string;
  snippet: string;
  url: string;
  sourceName: string;
  publishedAt: Date | null;
}

const NAMED_ENTITIES: Record<string, string> = {
  "&nbsp;": " ",
  "&amp;": "&",
  "&lt;": "<",
  "&gt;": ">",
  "&quot;": '"',
  "&apos;": "'",
  "&#39;": "'",
  "&hellip;": "…",
  "&mdash;": "—",
  "&ndash;": "–",
  "&rsquo;": "\u2019",
  "&lsquo;": "\u2018",
  "&ldquo;": "\u201C",
  "&rdquo;": "\u201D",
};

function decodeEntities(s: string): string {
  let out = s;
  for (const [k, v] of Object.entries(NAMED_ENTITIES)) {
    out = out.split(k).join(v);
  }
  out = out.replace(/&#(x?)([0-9a-fA-F]+);/g, (_, hex, num) => {
    const code = Number.parseInt(num, hex === "x" ? 16 : 10);
    return Number.isFinite(code) ? String.fromCodePoint(code) : "";
  });
  return out;
}

function stripHTML(s: string): string {
  // Decode first so that escaped tags (e.g. "&lt;a href=...&gt;") become real
  // tags that the regex below can strip; then decode again to clean up any
  // remaining entities inside the visible text.
  const decoded = decodeEntities(s);
  const stripped = decoded.replace(/<[^>]+>/g, " ");
  return decodeEntities(stripped).replace(/\s+/g, " ").trim();
}

function unwrapCDATA(s: string): string {
  return s.replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1").trim();
}

function readTag(item: string, tag: string): string {
  // Match <tag>...</tag> or <tag attr="...">...</tag>. Non-greedy, multi-line.
  const re = new RegExp(`<${tag}\\b[^>]*>([\\s\\S]*?)</${tag}>`, "i");
  const m = item.match(re);
  return m ? unwrapCDATA(m[1]).trim() : "";
}

function parseRSSDate(s: string): Date | null {
  if (!s) return null;
  const d = new Date(s);
  return Number.isFinite(d.getTime()) ? d : null;
}

/**
 * Parses Google News RSS into `NewsArticle[]`. Pure regex-based — no XML
 * dependency, robust enough for the well-formed feed Google produces.
 */
export function parseGoogleNewsRSS(xml: string, max: number): NewsArticle[] {
  const articles: NewsArticle[] = [];
  const itemRE = /<item\b[^>]*>([\s\S]*?)<\/item>/gi;
  let m: RegExpExecArray | null;
  while ((m = itemRE.exec(xml)) !== null && articles.length < max) {
    const item = m[1];

    let title = stripHTML(readTag(item, "title"));
    const link = readTag(item, "link");
    const rawDesc = readTag(item, "description");
    const desc = stripHTML(rawDesc);
    let source = readTag(item, "source");
    const pubDate = readTag(item, "pubDate");

    if (!title || !link) continue;

    // Google News titles often end with " - Source Name".
    if (!source) {
      const idx = title.lastIndexOf(" - ");
      if (idx > 0) {
        source = title.slice(idx + 3).trim();
        title = title.slice(0, idx).trim();
      }
    }

    let snippet = "";
    if (desc) {
      snippet = desc.length > 160 ? `${desc.slice(0, 160)}…` : desc;
    }

    articles.push({
      id: link,
      title,
      snippet,
      url: link,
      sourceName: source,
      publishedAt: parseRSSDate(pubDate),
    });
  }
  return articles;
}
