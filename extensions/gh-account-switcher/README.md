# GitHub Account Switcher (Raycast)

Quickly switch the active `gh` CLI account across hosts (github.com, GitHub Enterprise Server like `git.example.com`).

Wraps `gh auth switch` so you don't have to drop into a terminal.

## Commands

- **Switch GitHub Account** — interactive list of every account in `gh auth status`, grouped by host. Press Enter to switch the active account on that host.
- **Toggle GitHub Account** — no-view command that cycles to the next account on the configured host (default `github.com`). Great for binding to a Raycast hotkey.
- **Show Active GitHub Account** — HUD with the currently active user per host.

## Preferences

- **gh CLI Path** — optional override if `gh` isn't in a standard location.
- **Toggle Host** — host used by the toggle command. Defaults to `github.com`.

## Requirements

- [`gh`](https://cli.github.com) installed (`brew install gh`)
- At least two accounts logged in: `gh auth login` per account/host.

## Development

```bash
cd Extensions/gh-account-switcher
npm install
npm run dev
```
