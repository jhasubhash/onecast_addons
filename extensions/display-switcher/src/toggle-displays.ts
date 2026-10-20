import { showHUD, showToast, Toast } from "@raycast/api";
import { Display, MonitorConfig, getInput, getMonitorConfigs, listDisplays, setInput } from "./ddc";

interface Target {
  display: Display;
  config: MonitorConfig;
  current?: number;
}

/**
 * Only the Mac a monitor is showing can talk to it, so "toggle" means: send every monitor to the
 * other Mac's code. Which Mac this is comes from the first monitor whose current input is one of its
 * two codes (some monitors, like the Samsung, report the same value on every input).
 */
export default async function Command() {
  try {
    const configs = getMonitorConfigs();
    const displays = await listDisplays();

    const targets: Target[] = [];
    for (const config of configs) {
      const display = displays.find((d) => d.name.toLowerCase().includes(config.name.toLowerCase()));
      if (display) targets.push({ display, config, current: await getInput(display) });
    }
    if (targets.length === 0) {
      throw new Error(`None of ${configs.map((c) => c.name).join(", ")} is showing this Mac`);
    }

    const reference = targets.find((t) => t.current !== undefined && t.config.codes.includes(t.current));
    if (!reference) {
      const readings = targets.map((t) => `${t.config.name}: ${t.current ?? "?"}`).join(", ");
      throw new Error(`Can't tell which Mac is active (${readings})`);
    }
    const side = reference.config.codes.indexOf(reference.current!);
    const other = 1 - side;

    // Switch the reference monitor last: with a built-in KVM it takes the keyboard with it.
    const ordered = [...targets.filter((t) => t !== reference), reference];
    for (const t of ordered) await setInput(t.display, t.config.codes[other]);

    await showHUD(`Displays → other Mac (${ordered.map((t) => t.config.name).join(", ")})`);
  } catch (e) {
    await showToast({
      style: Toast.Style.Failure,
      title: "Display switch failed",
      message: e instanceof Error ? e.message : String(e),
    });
  }
}
