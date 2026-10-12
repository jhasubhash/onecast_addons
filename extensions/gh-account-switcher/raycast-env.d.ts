/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {
  /** gh CLI Path - Optional absolute path to the gh executable. Leave empty for auto-detection. */
  "ghPath": string,
  /** Toggle Host - Host used by the 'Toggle GitHub Account' command when cycling accounts. */
  "toggleHost": string,
  /** SSH Key Map - Optional. Mappings separated by ';' (or ','). Each mapping: 'host:user=/path/to/key' (or 'user=/path/to/key'). Use ~ for home. Example: github.com:work-user=~/.ssh/id_ed25519;github.com:jhasubhash=~/.ssh/id_ed25519_personal */
  "sshKeyMap": string,
  /** SSH Config Path - Optional override for the SSH config file. Defaults to ~/.ssh/config. */
  "sshConfigPath": string
}

/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `switch-account` command */
  export type SwitchAccount = ExtensionPreferences & {}
  /** Preferences accessible in the `toggle-account` command */
  export type ToggleAccount = ExtensionPreferences & {}
  /** Preferences accessible in the `show-active-account` command */
  export type ShowActiveAccount = ExtensionPreferences & {}
}

declare namespace Arguments {
  /** Arguments passed to the `switch-account` command */
  export type SwitchAccount = {}
  /** Arguments passed to the `toggle-account` command */
  export type ToggleAccount = {}
  /** Arguments passed to the `show-active-account` command */
  export type ShowActiveAccount = {}
}

