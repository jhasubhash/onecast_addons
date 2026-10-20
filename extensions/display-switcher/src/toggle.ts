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

const reports = (t: Target) => t.current !== undefined && t.config.codes.includes(t.current);

/**
 * Which Mac a monitor shows now: its reading when it reports one of its codes, otherwise the last
 * code this Mac sent it. A Mac can stay connected to a monitor showing the other Mac (the Samsung
 * keeps its HDMI link up), so "visible" doesn't mean "showing this Mac".
 */
async function resolveShowing(t: Target, side: () => Promise<number>): Promise<number> {
  if (reports(t)) return t.config.codes.indexOf(t.current!);
  const sent = await LocalStorage.getItem<number>(`showing:${t.config.name}`);
  return sent === 0 || sent === 1 ? sent : side();
}

/**
 * Flip each chosen monitor to the Mac it isn't showing, or with `reset`, send every monitor to the
 * Mac the primary (first configured) monitor shows. `pick` chooses the monitors from the configured
 * ones, in preference order.
 */
export async function toggle(pick: (configs: MonitorConfig[]) => MonitorConfig[], reset = false) {
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
      throw new Error(`${chosen.map((c) => c.name).join(", ")} isn't connected to this Mac`);
    }
    let side: number | undefined;
    const thisSide = async () => (side ??= await resolveSide(visible));
    if (visible.some(reports)) await thisSide(); // keep the remembered side fresh

    // The primary monitor's Mac: read when it's connected here, otherwise it shows the other Mac.
    let primarySide: number | undefined;
    if (reset) {
      const primary = visible.find((t) => t.config === configs[0]);
      primarySide = primary ? await resolveShowing(primary, thisSide) : 1 - (await thisSide());
    }

    // Switch a monitor that reports its input last: with a built-in KVM it takes the keyboard with it.
    const ordered = [...targets.filter((t) => !reports(t)), ...targets.filter(reports)];
    const moves: string[] = [];
    for (const t of ordered) {
      const next = primarySide ?? 1 - (await resolveShowing(t, thisSide));
      if (t.current !== t.config.codes[next]) await setInput(t.display, t.config.codes[next]);
      await LocalStorage.setItem(`showing:${t.config.name}`, next);
      moves.push(`${t.config.name} → ${next === (await thisSide()) ? "this Mac" : "other Mac"}`);
    }

    await showHUD(moves.join(", "));
  } catch (e) {
    await showToast({
      style: Toast.Style.Failure,
      title: "Display switch failed",
      message: e instanceof Error ? e.message : String(e),
    });
  }
}
