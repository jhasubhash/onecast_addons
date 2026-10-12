# LeetCode — an Onecast DockWidget

One LeetCode problem a day, turned into a streak game. The tile shows your streak and whether today
is done; clicking it opens the problem, a link to solve it, and everything you have earned.

- **compact** — the streak flame and count. A corner dot gives today's difficulty, a **green check**
  means done for the day, and a **pulsing red dot** means it is late (after the *nudge* hour) and
  nothing is solved yet.
- **wide** — adds today's title and difficulty, or *Done for today* once solved.
- **expanded** — adds the last seven days as dots (solved in its difficulty colour, frozen in blue).
- **popover** — the problem (number, difficulty, acceptance, topics), **Open in LeetCode**,
  **Solved** / **Undo**, **Skip** (three a day), your level and XP, a 16-week heatmap, badges, and a
  preferences panel.

## The daily loop

1. On the first tick of each day the widget gives the day a problem and keeps it until midnight.
2. Click the title or **Open in LeetCode**; the problem opens in your browser.
3. When you've solved it, press **Solved**. With a **username** set you needn't: every five minutes
   the widget checks your recent accepted submissions, and an accepted solution to today's problem
   submitted today marks the day done by itself ("Spotted your solve").
4. Once the day is done the tile stops nagging (green check) until tomorrow.

## Daily reminder

At the **reminder time** (default 20:00) Onecast posts one of its own notification cards, unless
today is already solved, in which case nothing appears. The card names your streak and today's
problem and has three buttons: **Open** (opens the problem), **Solved** (marks the day done) and
**In 1 hour** (snoozes it). Solving the day from the popover, or the widget spotting your solve,
takes down a card that is still up.

The reminder runs on Onecast's scheduler through `context.services`, so it keeps time with the
popover closed and is listed under **Settings → Scheduler → From plugins and widgets**, where it
can be switched off. If the Mac is asleep or Onecast is quit at the reminder time, it fires once on
return, but only on the same day; a reminder missed yesterday is dropped. It needs an Onecast build
that has DockWidget host services.

## The game

| Mechanic | Rule |
| --- | --- |
| **Streak** | Consecutive days solved. Today being open doesn't break it; missing a whole day does. |
| **XP** | Easy 10, Medium 25, Hard 50, plus 10% per streak day, capped at double. |
| **Levels** | Level *n* starts at 50·n·(n−1) XP (0, 100, 300, 600, 1000 …), titled Novice → Legend. |
| **Streak freezes** | One earned every 7 streak days (holding at most 2). A missed day is covered automatically if you have enough freezes for *every* missed day; frozen days keep the streak but don't add to it. |
| **Skips** | Three a day. A skipped problem is never suggested again. Skipping on a 7-day run voids *No Excuses*. |
| **Badges** | First Blood, Warming Up (3), On Fire (7), Unstoppable (30), Centurion (100), Hard Hitter, Ten Down, Half Century, Triple Digits, Early Bird (before 8 am), Night Owl (after 11 pm), No Excuses. |
| **Nudge** | From the nudge hour (default 18:00) an unsolved day pulses red on the tile, and the popover warns when a streak is at risk. |

**Undo** takes back the day's XP; best streak and badges stay, since they were earned at the time.

## Choosing problems

- **Pick for me** (default): a random free problem matching your **difficulty** (any mix of
  Easy / Medium / Hard; none means any) and **topics** (LeetCode tags; each day uses one at random).
  If a combination has nothing left, the picker loosens the topic, then the difficulty, rather than
  failing.
- **LeetCode daily challenge**: the official problem of the day, the same for everyone.

Set both in the popover's preferences panel (the sliders button) or in Settings. Changes apply to the
next problem; skip to use them today.

**Never repeats what you've solved.** Excluded from every pick: problems solved or skipped through
the widget, every problem it has assigned before, and, with a username, your last 20 accepted
submissions. To exclude *everything* you have ever solved, add your **session cookie**, which makes
LeetCode report each problem's status.

## Preferences

| Preference | Meaning |
| --- | --- |
| LeetCode username | Optional. Auto-detects solves, excludes recent solves, shows your profile totals in the popover. Public data, no sign-in. |
| Session cookie | Optional. The `LEETCODE_SESSION` cookie (DevTools → Application → Cookies → leetcode.com); a whole `Cookie:` string works too. Stored in Onecast's preferences in **plain text**. It expires every few weeks; when it does, picks just stop excluding older solves. |
| Problem source | Pick for me / LeetCode daily challenge. |
| Difficulty, Topics | As above. Topics are tag slugs such as `dynamic-programming`, `graph`, `sliding-window`. |
| Include Premium problems | Off by default. |
| Daily reminder | On by default: a Onecast notification at the reminder time unless today is solved. |
| Reminder time | `HH:mm`, 24-hour (default `20:00`). |
| Nudge from | Hour of the day (0–23) from which an unsolved day pulses. |

## Where the progress lives

The game state — every day's problem, solves, XP, freezes, badges — is one JSON file shared by all
LeetCode tiles:

```
~/Library/Application Support/<Onecast bundle id>/dockwidget-data/leetcode/state.json
```

It sits outside the `dockwidgets/` folder so saving it doesn't trigger a rebuild, and it survives
removing the tile. Two tiles read it before every change, so they agree. Delete the file to start
over.

Polling (a minute tick for the day rollover and nudge, a five-minute submission check) **pauses while
the Mac is locked or asleep** and catches up on unlock. Opening the popover checks straight away.

## Install

No build step; Onecast compiles it. Run **Reload DockWidgets** and pick LeetCode, or:

```sh
DEST="$HOME/Library/Application Support/com.onecast.app.dev/dockwidgets/leetcode"
mkdir -p "$DEST" && cp manifest.json *.swift "$DEST/"
```

## Layout

```
leetcode/
  manifest.json        identity, sizes, preferences
  LeetCodeWidget.swift widget class + entry point
  LCModel.swift        per-instance state: settings, assignment, solve detection, polling
  LCGame.swift         shared state file, streak/freeze/XP/level rules, badges
  LCData.swift         LeetCode GraphQL client, problem types, topic list
  LCViews.swift        tile, popover, heatmap, badges, preferences panel
  Presence.swift       lock/sleep detection that pauses polling
```
