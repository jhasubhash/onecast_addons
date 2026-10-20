import { LocalStorage, showHUD, showToast, Toast } from "@raycast/api";
import { Display, MonitorConfig, getInput, getMonitorConfigs, listDisplays, setInput } from "./ddc";

const SIDE_KEY = "side";

interface Target {
  display: Display;
  config: MonitorConfig;
  current?: number;
}

/**
 * Which Mac this is: 0 or 1, the index into every monitor's codes. Read from the first monitor whose
 * current input is one of its two codes (some monitors, like the Samsung, report the same value on
 * every input) and remembered, so a monitor can still be toggled while that one shows the other Mac.
 */
async function resolveSide(visible: Target[]): Promise<number> {
  const reference = visible.find((t) => t.current !== undefined && t.config.codes.includes(t.current));
  if (reference) {
    const side = reference.config.codes.indexOf(reference.current!);
    await LocalStorage.setItem(SIDE_KEY, side);
    return side;
  }
  const stored = await LocalStorage.getItem<number>(SIDE_KEY);
  if (stored === 0 || stored === 1) return stored;
  const readings = visible.map((t) => `${t.config.name}: ${t.current ?? "?"}`).join(", ");
  throw new Error(`Can't tell which Mac this is (${readings || "no monitor readings"})`);
}

/**
 * Only the Mac a monitor is showing can talk to it, so "toggle" means: send the chosen monitors to
 * the other Mac's code. `pick` chooses them from the configured monitors, in preference order.
 */
export async function toggle(pick: (configs: MonitorConfig[]) => MonitorConfig[]) {
  try {
    const configs = getMonitorConfigs();
    const chosen = pick(configs);
    if (chosen.length === 0) throw new Error("That monitor isn't configured in Monitor Inputs");

    const displays = await listDisplays();
    const visible: Target[] = [];
    for (const config of configs) {
      const display = displays.find((d) => d.name.toLowerCase().includes(config.name.toLowerCase()));
      if (display) visible.push({ display, config, current: await getInput(display) });
    }

    const targets = visible.filter((t) => chosen.includes(t.config));
    if (targets.length === 0) {
      throw new Error(`${chosen.map((c) => c.name).join(", ")} isn't showing this Mac`);
    }
    const other = 1 - (await resolveSide(visible));

    // Switch a monitor whose reading matches last: with a built-in KVM it takes the keyboard with it.
    const isReference = (t: Target) => t.current !== undefined && t.config.codes.includes(t.current);
    const ordered = [...targets.filter((t) => !isReference(t)), ...targets.filter(isReference)];
    for (const t of ordered) await setInput(t.display, t.config.codes[other]);

    await showHUD(`${ordered.map((t) => t.config.name).join(", ")} → other Mac`);
  } catch (e) {
    await showToast({
      style: Toast.Style.Failure,
      title: "Display switch failed",
      message: e instanceof Error ? e.message : String(e),
    });
  }
}
