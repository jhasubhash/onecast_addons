# Jira (Raycast)

Mirror of the BTT `JiraLauncherPlugin` plugin for Raycast: browse and search your Jira issues without leaving the keyboard.

## Setup

1. In Jira → **Profile → Personal Access Tokens**, create a token.
2. Open Raycast, run **List Jira Issues**, and on first launch you'll be prompted for:
   - **Base URL** — e.g. `https://jira.example.com`
   - **API Token (PAT)** — paste the token
   - **Default JQL** *(optional)*
   - **Max Results** *(optional, default 50)*

## Features

- **Tabs**: Assigned to me · Reported by me · Watching · Custom JQL (via search-bar dropdown)
- **Rich rows**: type icon, key chip, summary, status badge, priority chip, type label
- **Local filter** via Raycast search bar (filters loaded issues by key/summary/status/type)
- **Actions**: Open in Browser (↵), Copy URL (⌘U), Copy Key (⌘K), Refresh (⌘R), Edit Custom JQL (⌘E)
- Custom JQL is persisted to LocalStorage across sessions.

## API

`GET {baseURL}/rest/api/2/search?jql=...&fields=summary,status,issuetype,priority&maxResults=...`
with `Authorization: Bearer <PAT>`.
