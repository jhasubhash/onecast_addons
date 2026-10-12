/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {
  /** Base URL - Your Jira base URL, e.g. https://jira.example.com */
  "baseURL": string,
  /** API Token (PAT) - Personal Access Token used as a Bearer token in API calls. */
  "token": string,
  /** Default JQL - Initial JQL used when the extension opens. */
  "defaultJQL": string,
  /** Max Results - Maximum number of issues to fetch per query (1–200). */
  "maxResults": string
}

/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `list-issues` command */
  export type ListIssues = ExtensionPreferences & {}
}

declare namespace Arguments {
  /** Arguments passed to the `list-issues` command */
  export type ListIssues = {}
}

