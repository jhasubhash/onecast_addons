/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {
  /** Region & Language - Google News region/locale combination. */
  "region": "US:en" | "GB:en" | "IN:en" | "CA:en" | "AU:en" | "DE:de" | "FR:fr" | "JP:ja",
  /** Max Results - Maximum number of articles to fetch (1–50). */
  "maxResults": string,
  /** Show Thumbnails - Uses Clearbit logos with Google favicons as a fallback. */
  "showThumbnails": boolean
}

/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `search-news` command */
  export type SearchNews = ExtensionPreferences & {}
}

declare namespace Arguments {
  /** Arguments passed to the `search-news` command */
  export type SearchNews = {
  /** Search query */
  "query": string
}
}

