// Map of "source name as it appears in Google News RSS" → publisher domain.
// Anything not listed falls back to a heuristic in `domainForSource`.
const SOURCE_OVERRIDES: Record<string, string> = {
  "the new york times": "nytimes.com",
  "ny times": "nytimes.com",
  nyt: "nytimes.com",
  "the wall street journal": "wsj.com",
  "the washington post": "washingtonpost.com",
  "the guardian": "theguardian.com",
  "the economist": "economist.com",
  "the times of india": "timesofindia.indiatimes.com",
  "times of india": "timesofindia.indiatimes.com",
  "the hindu": "thehindu.com",
  "the indian express": "indianexpress.com",
  "the new indian express": "newindianexpress.com",
  ndtv: "ndtv.com",
  "ndtv profit": "ndtvprofit.com",
  "news on air": "newsonair.gov.in",
  "all india radio": "newsonair.gov.in",
  "al jazeera": "aljazeera.com",
  bbc: "bbc.com",
  "bbc news": "bbc.com",
  cnn: "cnn.com",
  cnbc: "cnbc.com",
  "cnbc tv18": "cnbctv18.com",
  reuters: "reuters.com",
  bloomberg: "bloomberg.com",
  "the verge": "theverge.com",
  "ars technica": "arstechnica.com",
  techcrunch: "techcrunch.com",
  engadget: "engadget.com",
  wired: "wired.com",
  "the atlantic": "theatlantic.com",
  "associated press": "apnews.com",
  "ap news": "apnews.com",
  ap: "apnews.com",
  dw: "dw.com",
  "dw.com": "dw.com",
  "dw news": "dw.com",
  yahoo: "yahoo.com",
  "yahoo news": "news.yahoo.com",
  "yahoo finance": "finance.yahoo.com",
  "fox news": "foxnews.com",
  "abc news": "abcnews.go.com",
  "cbs news": "cbsnews.com",
  "nbc news": "nbcnews.com",
  msnbc: "msnbc.com",
  "usa today": "usatoday.com",
  politico: "politico.com",
  axios: "axios.com",
  "the print": "theprint.in",
  moneycontrol: "moneycontrol.com",
  livemint: "livemint.com",
  mint: "livemint.com",
  "business standard": "business-standard.com",
  "the economic times": "economictimes.indiatimes.com",
  "economic times": "economictimes.indiatimes.com",
  "hindustan times": "hindustantimes.com",
  "india today": "indiatoday.in",
  firstpost: "firstpost.com",
  news18: "news18.com",
  wion: "wionews.com",
  scroll: "scroll.in",
  "the wire": "thewire.in",
  rediff: "rediff.com",
  "deccan herald": "deccanherald.com",
  "deccan chronicle": "deccanchronicle.com",
  "the telegraph": "telegraphindia.com",
  "telegraph india": "telegraphindia.com",
};

export function domainForSource(sourceName: string): string | null {
  const cleaned = sourceName.trim().toLowerCase();
  if (!cleaned) return null;

  const mapped = SOURCE_OVERRIDES[cleaned];
  if (mapped) return mapped;

  if (cleaned.includes(".")) {
    return cleaned.startsWith("www.") ? cleaned.slice(4) : cleaned;
  }

  let s = cleaned;
  if (s.startsWith("the ")) s = s.slice(4);
  const filtered = s.replace(/[^a-z0-9 -]/g, "");
  const compact = filtered.replace(/[\s-]/g, "");
  if (!compact) return null;
  return `${compact}.com`;
}

export function logoURLs(sourceName: string): { primary?: string; fallback?: string } {
  const domain = domainForSource(sourceName);
  if (!domain) return {};
  return {
    primary: `https://logo.clearbit.com/${domain}`,
    fallback: `https://www.google.com/s2/favicons?domain=${domain}&sz=128`,
  };
}
