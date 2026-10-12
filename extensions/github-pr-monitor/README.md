# GitHub PR Monitor

A Raycast extension that mirrors the BetterTouchTool `GitHubPRMonitor.swift` plugin: browse your **open PRs** and **review requests** for any GitHub repository, powered by the local [`gh`](https://cli.github.com/) CLI.

## Features

- **My Open PRs** — PRs you authored, still open
- **Review Requested** — PRs awaiting your review
- **Per-command repo preference** — configure `owner/repo` in command settings; leave blank to search across every repo you can access
- **Rich list UI** with PR number, draft tag, author, and relative "updated X ago"
- **Actions:** open in browser (↵), copy URL (⌘.C), copy PR number, refresh (⌘R), open settings
- **Auto-detects** `gh` at `/opt/homebrew/bin/gh`, `/usr/local/bin/gh`, etc. (override path in extension preferences)

## Requirements

- macOS with Raycast installed
- `gh` CLI installed and authenticated (`brew install gh && gh auth login`)

## Install (development)

```bash
cd github-pr-monitor
npm install
npm run dev      # opens the command in Raycast in dev mode
```

Then trigger **List GitHub PRs** from Raycast.
