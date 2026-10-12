# Kill Process

Onecast's answer to Activity Monitor's "Quit Process", and a port of Raycast's Kill Process: type a
name, see what it costs you, end it.

```
⌘⇧X   force kill (SIGKILL)     ⌘S   toggle memory / CPU sort
↵     quit (SIGTERM)           ⌘R   refresh        ⌘.   copy PID
```

## What it shows

One row per running process, sorted by resident memory (or CPU), with the owning application's real
icon. A helper is filed under the app that spawned it, so `Browser Helper (Renderer)` appears with
Dia's icon and Dia's name as its subtitle rather than as an anonymous binary.

Scope sits in the search bar:

| Scope | What it lists |
| --- | --- |
| **Apps** | Processes whose executable is the app itself — the things with a window. The default. |
| **Mine** | Everything running as you, helpers and daemons included. |
| **All** | The whole table, `root` and system daemons too. |

## Ending a process

**Quit** sends `SIGTERM` and never asks: the process can catch it, flush, and exit cleanly.
**Force Kill** sends `SIGKILL`, which cannot be caught, so it confirms first — turn that off in
preferences if you would rather it didn't.

A signalled row disappears immediately and **stays** gone. A dying process keeps appearing in
`ps` for a while — 255-704 ms for a trivial one, seconds for an app that flushes state first — so
the pid is hidden until `ps` confirms the exit, rather than being filtered once and then put back by
the next refresh. If it is still there after that, the row returns with *"it ignored the quit
request"*: `SIGTERM` is catchable, so "signalled" is not "gone", and hiding it forever would be a
lie you would act on. Processes in state `Z` are left out entirely — they have already exited and
are only waiting to be reaped.

Every outcome is announced with `showHUD` — the pill at the bottom of the screen, the same place
every other extension here reports from. `showToast` draws *inside* the extension's own view, which
puts a panel over the list you are working in.

Two outcomes are reported honestly rather than as generic failures:

- **Already exited.** A row can name a pid that died between the last refresh and your keystroke.
  `kill` calls that an error; this doesn't — you wanted it gone, and it is.
- **Owned by root.** `Operation not permitted` becomes _"launchd runs as root; signalling it needs
  sudo"_, because no amount of retrying will change the answer.

## How it reads the table

```sh
/bin/ps -Ao pid=,pcpu=,rss=,user=,comm=
```

`/bin/ps` by absolute path, deliberately: the `ps` that may sit earlier on `PATH` is not BSD `ps`,
and it truncates `comm` to a bare, cropped name — `Browser Helper ` — with no path at all. The full
path is what makes the owning bundle, and therefore the icon, recoverable. Since the four fields
before `comm` can never contain a space, everything past the fourth is the path, spaces and all.

## Install

```sh
npm install && npm run build && ./install.sh
```

Onecast picks the install up on its own; no rescan or relaunch needed.
