# Google AI Mode

Ask Google's [AI Mode](https://www.google.com/search?udm=50) from the Onecast launcher and keep
chatting with it there. Google draws the page itself in a web view (it has no public API), so
answers, sources and the follow-up box are Google's own.

## Use

- **Google AI Mode** in the launcher opens the plugin. Type a question, then press ↩ to ask.
- Type in Google's **Ask anything** box at the bottom to follow up.
- Esc goes back to your threads; Esc again leaves the plugin.
- Your threads are listed newest first, and typing filters them. ↑/↓ and ↩ reopen one.
- **⌘K** offers:
  - Clear Conversation (in a thread): empties it in place and shows a field for a new question,
    which then becomes the thread. Leaving it empty drops it from the list.
  - Pop Out
  - Add to Main Menu
  - Copy Deep Link
  - Open in Browser
  - Copy Link
  - Reload
  - Delete Thread / Delete All Threads (on the thread list)
  - Sign In to Google
  - Sign Out and Clear Google Data
- **Pop Out** moves the live conversation into its own window; nothing reloads. The window's ⌘K
  offers Clear Conversation, Reload, Open in Browser and Copy Link above its window controls.
  Pop-outs reopen when Onecast relaunches.
- **Ask straight from the launcher:** add a Quicklink whose link is
  `onecast://plugin/com.sujha.googleaimode?q={Query}`, for example with the alias `gai`.

## How it behaves

- A thread keeps the page's latest address, which carries Google's conversation token. So a thread
  reopened after a relaunch normally continues where it stopped.
- The six most recently used threads stay live in memory. Older ones reload from their saved link.
- Cookies and the Google sign-in live in the plugin's own persistent website data store, apart from
  Safari's. **Sign Out and Clear Google Data** wipes that store.
- Result links open in your default browser; Google's own pages stay in the panel.
- **Show only the conversation** (on by default) fits the page to the launcher:
  - hides Google's logo, tabs, account bar, side menu and footer;
  - clears the page's own background so the launcher's backdrop shows through;
  - uses the system font, and the launcher's translucent fills for message bubbles, cards and
    small buttons, with hairline borders;
  - makes the **Ask anything** box frosted glass with the launcher's 12pt corners, so the
    answer blurs as it scrolls under it;
  - uses the macOS accent colour for the caret and text selection.

  The script finds these parts by id, position and computed style, never by Google's generated
  class names. It re-applies as an answer streams in, and leaves every other Google page alone.
  A page stays hidden behind a small spinner until the first pass has run, so Google's own
  layout never flashes. If nothing matches within 4 seconds, the page shows anyway.
  Turn the setting off to get the full page back; threads opened after the change pick it up.
- Settings › Plugins › Google AI Mode controls this, the page zoom and how many threads to keep.

## Limits

- Google may refuse a sign-in from an embedded web view. AI Mode works signed out.
- Google can change its page at any time. If a hidden part comes back, the chat-only script needs
  a new rule. The plugin reads nothing from the page.

## Install

```sh
DEST="$HOME/Library/Application Support/com.onecast.app.dev/plugins/google-ai-mode"
mkdir -p "$DEST" && cp manifest.json *.swift "$DEST/"
```
