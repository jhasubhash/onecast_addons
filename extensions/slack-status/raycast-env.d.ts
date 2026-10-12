/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {
  /** Slack User Token - A Slack user OAuth token (xoxp-…) with users.profile:write and users.profile:read scopes. */
  "token": string,
  /** Presets (JSON) - Optional JSON array overriding the built-in presets. Each item: { "emoji": ":coffee:", "text": "Coffee Break", "minutes": 15 }. Leave empty to use defaults. */
  "presetsJSON": string,
  /** Profile Photo - When on, setting a Lunch status switches your Slack photo to a random lunch photo, and any other status (or clearing) restores the day-of-week photo. */
  "syncProfilePhoto": boolean
}

/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `set-status` command */
  export type SetStatus = ExtensionPreferences & {}
  /** Preferences accessible in the `clear-status` command */
  export type ClearStatus = ExtensionPreferences & {}
  /** Preferences accessible in the `set-profile-photo-main` command */
  export type SetProfilePhotoMain = ExtensionPreferences & {}
  /** Preferences accessible in the `set-profile-photo-fun` command */
  export type SetProfilePhotoFun = ExtensionPreferences & {}
  /** Preferences accessible in the `status-afk` command */
  export type StatusAfk = ExtensionPreferences & {}
  /** Preferences accessible in the `status-lunch` command */
  export type StatusLunch = ExtensionPreferences & {}
  /** Preferences accessible in the `status-ooo` command */
  export type StatusOoo = ExtensionPreferences & {}
  /** Preferences accessible in the `status-sick` command */
  export type StatusSick = ExtensionPreferences & {}
  /** Preferences accessible in the `status-pto` command */
  export type StatusPto = ExtensionPreferences & {}
  /** Preferences accessible in the `status-vacation` command */
  export type StatusVacation = ExtensionPreferences & {}
  /** Preferences accessible in the `status-oncall` command */
  export type StatusOncall = ExtensionPreferences & {}
  /** Preferences accessible in the `restore-photo` command */
  export type RestorePhoto = ExtensionPreferences & {}
}

declare namespace Arguments {
  /** Arguments passed to the `set-status` command */
  export type SetStatus = {}
  /** Arguments passed to the `clear-status` command */
  export type ClearStatus = {}
  /** Arguments passed to the `set-profile-photo-main` command */
  export type SetProfilePhotoMain = {}
  /** Arguments passed to the `set-profile-photo-fun` command */
  export type SetProfilePhotoFun = {}
  /** Arguments passed to the `status-afk` command */
  export type StatusAfk = {}
  /** Arguments passed to the `status-lunch` command */
  export type StatusLunch = {}
  /** Arguments passed to the `status-ooo` command */
  export type StatusOoo = {}
  /** Arguments passed to the `status-sick` command */
  export type StatusSick = {}
  /** Arguments passed to the `status-pto` command */
  export type StatusPto = {}
  /** Arguments passed to the `status-vacation` command */
  export type StatusVacation = {}
  /** Arguments passed to the `status-oncall` command */
  export type StatusOncall = {}
  /** Arguments passed to the `restore-photo` command */
  export type RestorePhoto = {}
}

