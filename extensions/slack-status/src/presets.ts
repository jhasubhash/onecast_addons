import { getPreferenceValues } from "@raycast/api";

export interface Preset {
  emoji: string; // ":coffee:" style
  text: string;
  minutes: number; // 0 = don't clear
}

export const DURATION_OPTIONS: { title: string; minutes: number }[] = [
  { title: "Don't clear", minutes: 0 },
  { title: "15 minutes", minutes: 15 },
  { title: "30 minutes", minutes: 30 },
  { title: "45 minutes", minutes: 45 },
  { title: "1 hour", minutes: 60 },
  { title: "1.5 hours", minutes: 90 },
  { title: "2 hours", minutes: 120 },
  { title: "3 hours", minutes: 180 },
  { title: "4 hours", minutes: 240 },
  { title: "8 hours", minutes: 480 },
  { title: "1 day", minutes: 1440 },
  { title: "3 days", minutes: 1440 * 3 },
  { title: "1 week", minutes: 1440 * 7 },
];

export const DEFAULT_PRESETS: Preset[] = [
  { emoji: ":tea:", text: "Away from Keyboard", minutes: 15 },
  { emoji: ":hamburger:", text: "Lunch", minutes: 45 },
  { emoji: ":palm_tree:", text: "Out of Office", minutes: 1440 },
  { emoji: ":face_with_thermometer:", text: "Out Sick", minutes: 1440 },
  { emoji: ":red_circle:", text: "On PTO Today", minutes: 1440 },
  { emoji: ":airplane:", text: "On Vacation", minutes: 0 },
  { emoji: ":telephone_receiver:", text: "On Call", minutes: 0 },
];

interface Prefs {
  presetsJSON?: string;
}

/** Parse the presets-JSON preference, falling back to defaults on empty/invalid input. */
export function loadPresets(): { presets: Preset[]; error?: string } {
  const { presetsJSON } = getPreferenceValues<Prefs>();
  const raw = (presetsJSON ?? "").trim();
  if (!raw) return { presets: DEFAULT_PRESETS };
  try {
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) throw new Error("Expected a JSON array");
    const cleaned: Preset[] = parsed.map((p, i) => {
      if (typeof p !== "object" || p === null) throw new Error(`Item ${i} is not an object`);
      const emoji = String((p as Record<string, unknown>).emoji ?? "");
      const text = String((p as Record<string, unknown>).text ?? "");
      const minutes = Number((p as Record<string, unknown>).minutes ?? 0);
      if (!text) throw new Error(`Item ${i} missing "text"`);
      return { emoji, text, minutes: Number.isFinite(minutes) ? minutes : 0 };
    });
    return { presets: cleaned.length ? cleaned : DEFAULT_PRESETS };
  } catch (e) {
    return { presets: DEFAULT_PRESETS, error: (e as Error).message };
  }
}

export function durationLabel(minutes: number): string {
  if (!minutes || minutes <= 0) return "no expiration";
  if (minutes < 60) return `${minutes} minutes`;
  if (minutes < 1440) {
    const h = minutes / 60;
    return h === Math.floor(h) ? `${h} hour${h === 1 ? "" : "s"}` : `${h} hours`;
  }
  const d = minutes / 1440;
  return d === Math.floor(d) ? `${d} day${d === 1 ? "" : "s"}` : `${d} days`;
}
