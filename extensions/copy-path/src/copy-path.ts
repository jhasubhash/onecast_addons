import {
  Clipboard,
  Toast,
  getFrontmostApplication,
  getPreferenceValues,
  getSelectedFinderItems,
  showHUD,
  showToast,
} from "@raycast/api";
import { execFileSync } from "node:child_process";

type Preferences = { separator?: string; quotePaths?: boolean };

// Which AppleScript dialect a browser answers to: Chromium exposes the address bar as
// `active tab of front window`, WebKit as `front document`.
const BROWSER_DIALECT: Record<string, "chromium" | "webkit"> = {
  "com.google.Chrome": "chromium",
  "com.google.Chrome.beta": "chromium",
  "com.google.Chrome.canary": "chromium",
  "com.brave.Browser": "chromium",
  "com.brave.Browser.beta": "chromium",
  "com.microsoft.edgemac": "chromium",
  "com.microsoft.edgemac.Beta": "chromium",
  "company.thebrowser.Browser": "chromium",
  "company.thebrowser.dia": "chromium",
  "com.vivaldi.Vivaldi": "chromium",
  "com.operasoftware.Opera": "chromium",
  "org.chromium.Chromium": "chromium",
  "ai.perplexity.comet": "chromium",
  "com.apple.Safari": "webkit",
  "com.apple.SafariTechnologyPreview": "webkit",
  "com.kagi.kagimacOS": "webkit",
};

const SEPARATORS: Record<string, string> = { newline: "\n", space: " ", comma: ", " };

type Frontmost = { name: string; bundleId?: string };

function osascript(script: string): string {
  return execFileSync("osascript", ["-e", script], { encoding: "utf8", timeout: 10_000 }).trim();
}

// AppleScript prints a missing value as the literal text "missing value"; that means "no answer".
function answer(value: string): string {
  return value === "missing value" ? "" : value;
}

// The page URL of the focused window's web area, read straight from the accessibility API. Browsers
// whose AppleScript dictionary is broken (Crest declares Chromium's but answers no `window`) and that
// leave AXDocument unset still expose AXURL on their AXWebArea — System Events can see that attribute
// but fails to coerce its NSURL, so this goes through JXA instead. Breadth-first, so the page itself
// wins over any web area nested inside it.
const AX_WEB_URL = `
ObjC.import('AppKit');
ObjC.bindFunction('AXUIElementCreateApplication', ['id', ['int']]);
ObjC.bindFunction('AXUIElementCopyAttributeValue', ['int', ['id', 'id', 'id*']]);
function run(argv) {
  const app = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(argv[0]).firstObject;
  if (!app) return '';
  const get = (el, name) => { const r = Ref(); return $.AXUIElementCopyAttributeValue(el, $(name), r) === 0 ? r[0] : null; };
  const win = get($.AXUIElementCreateApplication(app.processIdentifier), 'AXFocusedWindow');
  const queue = win ? [win] : [];
  for (let seen = 0; queue.length && seen < 2000; seen++) {
    const el = queue.shift();
    if (ObjC.unwrap(get(el, 'AXRole')) === 'AXWebArea') {
      const url = get(el, 'AXURL');
      if (url) return ObjC.unwrap(url.absoluteString);
    }
    const kids = get(el, 'AXChildren');
    if (kids) for (let i = 0; i < kids.count; i++) queue.push(kids.objectAtIndex(i));
  }
  return '';
}`;

function webAreaURL(bundleId: string): string {
  try {
    return answer(
      execFileSync("osascript", ["-l", "JavaScript", "-e", AX_WEB_URL, bundleId], { encoding: "utf8", timeout: 10_000 }).trim()
    );
  } catch {
    return "";
  }
}

/// What the frontmost app is pointing at, named for the HUD.
async function resolve(app: Frontmost, preferences: Preferences): Promise<{ label: string; value: string }> {
  const bundleId = app.bundleId ?? "";

  if (bundleId === "com.apple.finder") {
    const selected = (await getSelectedFinderItems()).map((item) => item.path);
    // Nothing selected still has an answer: the folder the window is showing.
    const paths = selected.length
      ? selected
      : [osascript('tell application "Finder" to return POSIX path of (target of front window as alias)')];
    const quoted = preferences.quotePaths ? paths.map((p) => (p.includes(" ") ? `"${p}"` : p)) : paths;
    return {
      label: paths.length > 1 ? `${paths.length} paths` : "path",
      value: quoted.join(SEPARATORS[preferences.separator ?? "newline"] ?? "\n"),
    };
  }

  const dialect = BROWSER_DIALECT[bundleId];
  if (dialect) {
    const target = dialect === "chromium" ? "URL of active tab of front window" : "URL of front document";
    return { label: "URL", value: osascript(`tell application id "${bundleId}" to return ${target}`) };
  }

  // Every other app: the front window's AXDocument, which document-based apps set to a file:// URL
  // and browsers without AppleScript support set to the page address. The process has to be bound to
  // a variable first — inlining the `whose` filter into the `tell` resolves it to `process 1`.
  // A closed or minimised window raises "Invalid index" rather than answering, which says the same
  // thing as an empty result: this app has nothing to give us.
  let document = "";
  try {
    document = answer(osascript(
      `tell application "System Events"
         set proc to first process whose bundle identifier is "${bundleId}"
         return value of attribute "AXDocument" of window 1 of proc
       end tell`
    ));
  } catch {
    document = "";
  }
  if (!document) document = webAreaURL(bundleId);
  if (!document) throw new Error(`${app.name} has no file or URL in its front window`);
  if (!document.startsWith("file://")) return { label: "URL", value: document };
  return { label: "path", value: decodeURIComponent(document.slice("file://".length)) };
}

export default async function Command() {
  const app = (await getFrontmostApplication()) as Frontmost;
  try {
    const { label, value } = await resolve(app, getPreferenceValues<Preferences>());
    if (!value) throw new Error(`Nothing to copy from ${app.name}`);
    await Clipboard.copy(value);
    await showHUD(`Copied ${label} from ${app.name}`);
  } catch (error) {
    await showToast({
      style: Toast.Style.Failure,
      title: `Couldn't copy from ${app.name}`,
      message: error instanceof Error ? error.message.split("\n").pop() : String(error),
    });
  }
}
