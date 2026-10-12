# Slack Status (Raycast)

Set, change, or clear your Slack status without leaving Raycast. Uses the Slack Web API directly with a user OAuth token (xoxp-…) — no app authorization flow.

## Commands

- **Set Slack Status** — list current status + built-in presets, override duration per preset, or open a custom status form.
- **Clear Slack Status** — one-shot clear (silent).
- **Set Profile Picture: Main** / **Set Profile Picture: Fun** — set your Slack profile picture to a random image from `assets/main/` or `assets/fun/`. Whichever you pick last persists: status changes, clearing your status, and the background restore command (below) all resolve back to it, until you run the other one.

## Preferences

- **Slack User Token** — `xoxp-…` token with `users.profile:read` + `users.profile:write` scopes.
- **Presets (JSON)** — optional override for the built-in preset list. Example:

  ```json
  [
    { "emoji": ":coffee:", "text": "Coffee Break", "minutes": 15 },
    { "emoji": ":brain:", "text": "Focus Mode", "minutes": 180 }
  ]
  ```

## Built-in presets

- :brain: Focus Mode — 3 hours
- :coffee: Coffee Break — 15 minutes
- :dog: Walking Zola — 1.5 hours
- :hamburger: Lunch — 1 hour
- :shopping_trolley: At the shop — 2 hours
- :weight_lifter: Gym — 1.5 hours

## Custom status

The custom form accepts an emoji code (e.g. `:airplane:`), free-form status text, and a "Clear After" duration. Setting **Don't clear** sends `status_expiration: 0`, matching Slack's "no expiration" behavior.

## Profile photo

When **Sync profile photo with status** is on, a Lunch/PTO/Out Sick/On Call status swaps in a random photo from that status's own asset set, and clearing the status (or its expiration passing) restores whichever of Main/Fun is currently persisted. Drop more images into `assets/main/` or `assets/fun/` (named `main-<n>.png` / `fun-<n>.png`) to grow either set.
