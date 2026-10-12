import { Clipboard, getPreferenceValues, getSelectedText, open, showHUD, showToast, Toast } from "@raycast/api";

interface Prefs {
  baseURL: string;
}

function normaliseBaseURL(url: string): string {
  return url.trim().replace(/\/+$/, "");
}

// Jira keys look like DISE-19408: a project key (letter followed by letters/digits)
// then a dash and the issue number.
const ISSUE_KEY_RE = /[A-Z][A-Z0-9]+-\d+/;

export default async function Command() {
  const { baseURL } = getPreferenceValues<Prefs>();

  // getSelectedText() only reads the selection of the frontmost *app*. When the command is
  // triggered from the floating window (which has no app selection), it throws — so fall back
  // to the clipboard, letting the user copy the key (Cmd+C) instead of selecting it.
  let selection = "";
  try {
    selection = await getSelectedText();
  } catch {
    selection = "";
  }
  if (!ISSUE_KEY_RE.test(selection.toUpperCase())) {
    selection = (await Clipboard.readText()) ?? "";
  }

  const match = selection.toUpperCase().match(ISSUE_KEY_RE);
  if (!match) {
    await showToast({
      style: Toast.Style.Failure,
      title: "No Jira issue key found",
      message: "Select or copy a key like DISE-19408 first.",
    });
    return;
  }

  const key = match[0];
  const url = `${normaliseBaseURL(baseURL)}/browse/${encodeURIComponent(key)}`;
  await open(url);
  await showHUD(`Opening ${key}`);
}
