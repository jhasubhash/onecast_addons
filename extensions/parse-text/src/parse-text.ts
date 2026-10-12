import { Clipboard, Toast, getSelectedText, showHUD, showToast } from "@raycast/api";

// A URL can never legally contain whitespace, so when a selection is *only* a URL that a soft
// line-wrap split across lines, the line breaks are spurious and can be removed to reassemble the
// original single-line link. We only ever delete whitespace runs that CONTAIN a newline (the wrap
// break plus any indentation the next line carries) — a lone space is never touched, so a real URL
// sitting inside prose ("see this https://a.com/x") is never mistaken for a bare link, and ordinary
// text (which may legitimately contain newlines) is copied verbatim.

// Remove wrap breaks only: a run of whitespace that includes a newline, plus surrounding spaces/tabs.
function stripWrapBreaks(text: string): string {
  return text.replace(/[ \t]*\r?\n\s*/g, "");
}

// Is `candidate` a single URL we recognise? Any interior whitespace disqualifies it.
function isLink(candidate: string): boolean {
  if (!candidate || /\s/.test(candidate)) return false;
  // scheme://rest  (http, https, ftp, ...), or a bare www.host.tld
  if (/^[a-z][a-z0-9+.-]*:\/\/[^\s]+$/i.test(candidate)) return true;
  if (/^www\.[^\s]+\.[^\s]+$/i.test(candidate)) return true;
  return false;
}

/// Given a raw selection, return the text to copy and whether it was cleaned as a wrapped link.
function cleanSelection(raw: string): { value: string; cleaned: boolean } {
  const trimmed = raw.trim();
  if (!trimmed) return { value: raw, cleaned: false };

  const collapsed = stripWrapBreaks(trimmed);
  if (isLink(collapsed)) {
    return { value: collapsed, cleaned: collapsed !== trimmed };
  }
  // Not a pure link: copy the selection unchanged.
  return { value: raw, cleaned: false };
}

export default async function Command() {
  // Prefer the live selection; when nothing is selected (getSelectedText throws or returns empty),
  // fall back to whatever was last copied to the clipboard so the command still cleans a link
  // you already have on hand.
  let text = "";
  let source: "selection" | "clipboard" = "selection";
  try {
    text = await getSelectedText();
  } catch {
    text = "";
  }
  if (!text.trim()) {
    text = (await Clipboard.readText()) ?? "";
    source = "clipboard";
  }

  if (!text.trim()) {
    await showToast({
      style: Toast.Style.Failure,
      title: "Nothing to copy",
      message: "Select some text or copy a link first, then run Copy Clean Link.",
    });
    return;
  }

  const { value, cleaned } = cleanSelection(text);
  await Clipboard.copy(value);
  await showHUD(
    cleaned
      ? `Copied link (unwrapped) from ${source}`
      : `Copied ${source}`,
  );
}
