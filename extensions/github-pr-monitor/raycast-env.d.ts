/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {
  /** GitHub Accounts - Which gh CLI accounts to fetch PRs from. 'Active only' is fastest; 'All' fans out across every logged-in account in ~/.config/gh/hosts.yml. */
  "accounts": "active" | "all",
  /** gh CLI Path - Optional absolute path to the gh executable. Leave empty for auto-detection. */
  "ghPath": string,
  /** Claude CLI Path - Optional absolute path to the claude executable used for PR reviews. Leave empty to resolve from PATH. */
  "claudePath": string,
  /** PR Review Script - Optional absolute path to a shell script that performs the PR review. Receives the PR URL as $1 and the env vars PR_URL, PR_NUMBER, PR_REPO, PR_TITLE, PR_AUTHOR, PR_HOST, PR_ACCOUNT. If set, overrides the built-in claude invocation. */
  "reviewScript": string,
  /** Claude Review Prompt - Prompt passed to `claude -p` when no review script is set. Use {URL} as a placeholder for the PR URL. */
  "reviewPrompt": string
}

/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `list-prs` command */
  export type ListPrs = ExtensionPreferences & {
  /** Include Repositories - Comma-separated list of repos to include, in owner/name format (e.g. acme/api,acme/web). Supports wildcards: owner/* matches every repo under an owner, and * matches everything. Leave blank to search across all repos you can access. */
  "repo": string,
  /** Exclude Repositories - Comma-separated list of repos to exclude, in owner/name format. Supports wildcards: owner/* excludes every repo under an owner. Applied after Include Repositories. */
  "excludeRepo": string
}
}

declare namespace Arguments {
  /** Arguments passed to the `list-prs` command */
  export type ListPrs = {}
}

