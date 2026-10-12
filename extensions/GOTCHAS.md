# Onecast extension gotchas

Behaviors where Onecast's `@raycast/api` runtime differs from real Raycast. Each cost real
debugging time; read before writing a multi-screen (`Action.Push`) extension.

## The palette search field is shared across the whole navigation stack, and is NOT cleared on push

Real Raycast gives every pushed `<List>`/`<Grid>` its own search text and clears the bar when you
push a detail view. Onecast keeps a single palette query (`vm.query`) for the entire stack and
carries it into the child unchanged.

Symptom: you type a query in the root list to find a row, press Enter to push a detail list, and the
child list opens still filtered by that query — often down to a single unrelated row that happens to
match on a subtitle. Pressing Escape (which clears the query before it pops) reveals the full child
list, "proving" the child is fine.

Example: typing `blemish` to find a service, then Enter, left the pushed category list
(`Identity & IDs`, `Repositories`, `Deployments`, …) filtered by `blemish`. Only `Repositories`
survived — its subtitle `org/blemish-deploy` matched — so the drill-in looked like it opened the
wrong row.

Fix: clear the search bar when a pushed list mounts (same effect as the Escape the user would
otherwise press). `clearSearchBar` is exported from `@raycast/api` and maps to the host command that
sets `vm.query = ""`.

```ts
import { clearSearchBar } from "@raycast/api";

useEffect(() => {
  void clearSearchBar();
}, []); // on mount of every pushed List/Grid — NOT the root command list
```

Do not call it in the root command's list: that list *should* keep what the user typed.

## A pushed List inherits the parent's numeric selection index, not the top row

Onecast restores selection by position, so a pushed list lands on the Nth row (where N was the
highlighted index in the parent) instead of its first row.

Fix: control `selectedItemId`, seed it to the first item's id, and let `onSelectionChange` follow the
user. Every item needs a stable `id` so tracking is by id, not index.

```ts
function useFreshList(firstId: string) {
  const [selectedItemId, setSelectedItemId] = useState(firstId);
  useEffect(() => {
    void clearSearchBar(); // also fixes the shared-search gotcha above
  }, []);
  const onSelectionChange = (id: string | null) => {
    if (id) setSelectedItemId(id);
  };
  return { selectedItemId, onSelectionChange };
}

// <List {...useFreshList("first-row-id")}> ... </List>
```

## `ExtensionScreen` reads only a fixed set of List props

Controlling a child list's `searchText`/`onSearchTextChange` does not clear the shared palette query —
the Swift `ExtensionScreen` only reads `searchBarPlaceholder`, `onSearchTextChange`, `selectedItemId`,
`filtering`, and `searchBarAccessory` off the root node. Use `clearSearchBar()` (above), not a
controlled `searchText`, to reset the field on navigation.

## A single click on a List row runs its primary action

Real Raycast selects a row on click and runs the primary action on ↵ or double-click. Onecast's
`ExtensionListView` does both on one click (`onSelect` then `onActivate`). In a master/detail list
(`isShowingDetail`) where clicking should only switch the detail pane, a primary action like
`Action.CopyToClipboard` copies and closes the window instead.

Fix: choose the first action per row from the controlled `selectedItemId`. On non-selected rows make
it a harmless select ("Show Answer", which sets `selectedItemId`); on the selected row make it the
real action (copy). This is safe because `ExtensionCommandScreen.activate(at:)` reads the action
panel as last rendered: a click selects and activates synchronously, before JS re-renders, so the
first click on another row always hits the select. A second click (or ↵) then runs the real action.

## `fs.cpSync` is missing from the runtime's Node shim

Onecast's Node shim does not implement `fs.cpSync` (fails with "fs.cpSync is not a function"). Walk
directories manually with `fs.readdirSync` + `fs.copyFileSync` when copying nested trees (e.g.
`assets/`).

## Loading an extension into Onecast

Extensions are Raycast-compatible. Build the CJS bundle with esbuild, then copy exactly what
`ExtensionCatalog.install` copies — `package.json`, one `<command>.js` per declared command, and
`assets/` — into the app's extensions dir. `install.sh` does this; `npm run ship` builds + installs.

Deep link to launch a command directly:
`onecast://extensions/<author>/<extension-name>/<command-name>` (the `raycast://` scheme also works).
Onecast watches its extensions folder, so an install or reinstall — including added, renamed or
removed commands — reaches the launcher by itself; no Settings visit or restart needed.
