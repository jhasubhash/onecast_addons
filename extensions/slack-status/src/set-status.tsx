import {
  Action,
  ActionPanel,
  Color,
  Form,
  Icon,
  List,
  Toast,
  closeMainWindow,
  showHUD,
  showToast,
  useNavigation,
  openExtensionPreferences,
} from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import {
  SlackProfile,
  clearStatus,
  expirationFromMinutes,
  formatExpiration,
  getCurrentStatus,
  setStatus,
} from "./slack";
import { DEFAULT_PRESETS, DURATION_OPTIONS, Preset, durationLabel, loadPresets } from "./presets";
import { emojiGlyph } from "./emoji";
import { syncProfilePhoto } from "./actions";

export default function Command() {
  const { presets, error: presetsError } = loadPresets();

  const {
    data: current,
    isLoading,
    revalidate,
    error,
  } = useCachedPromise(() => getCurrentStatus(), [], {
    keepPreviousData: true,
    onError: (err) => {
      void showToast({ style: Toast.Style.Failure, title: "Couldn't load Slack status", message: err.message });
    },
  });

  async function applyStatus(emoji: string, text: string, minutes: number) {
    // Dismiss Raycast right away, apply the fast status change + confirm, then
    // upload the slower profile photo in the background so it never delays UI.
    await closeMainWindow({ clearRootSearch: true });
    try {
      await setStatus(emoji, text, expirationFromMinutes(minutes));
      const suffix = minutes > 0 ? ` (${durationLabel(minutes)})` : "";
      await showHUD(`✅ Status set: ${text}${suffix}`);
      await syncProfilePhoto(emoji, text);
    } catch (e) {
      await showHUD(`❌ Failed to set status: ${(e as Error).message}`);
    }
  }

  async function applyClear() {
    await closeMainWindow({ clearRootSearch: true });
    try {
      await clearStatus();
      await showHUD("✅ Status cleared");
      await syncProfilePhoto("", "");
    } catch (e) {
      await showHUD(`❌ Failed to clear status: ${(e as Error).message}`);
    }
  }

  return (
    <List isLoading={isLoading} searchBarPlaceholder="Search presets…">
      <List.Section title="Current Status">
        <CurrentStatusRow
          current={current}
          loadError={error?.message}
          onClear={applyClear}
          onSetCustom={() => applyStatus}
          onRefresh={revalidate}
          presets={presets}
          applyStatus={applyStatus}
        />
      </List.Section>

      <List.Section title="Presets" subtitle={presetsError ? `Invalid presets JSON: ${presetsError}` : undefined}>
        {presets.map((p, idx) => (
          <PresetRow
            key={`${p.emoji}-${p.text}-${idx}`}
            preset={p}
            applyStatus={applyStatus}
            onClear={applyClear}
            onRefresh={revalidate}
          />
        ))}
      </List.Section>
    </List>
  );
}

function CurrentStatusRow({
  current,
  loadError,
  onClear,
  onRefresh,
  applyStatus,
}: {
  current?: SlackProfile;
  loadError?: string;
  onClear: () => void;
  onSetCustom: () => unknown;
  onRefresh: () => void;
  presets: Preset[];
  applyStatus: (emoji: string, text: string, minutes: number) => Promise<void>;
}) {
  const { push } = useNavigation();
  const hasStatus = !!current && (current.status_text || current.status_emoji);
  const expiry = current?.status_expiration ? formatExpiration(current.status_expiration) : "";

  return (
    <List.Item
      icon={hasStatus ? emojiGlyph(current!.status_emoji) : { source: Icon.SpeechBubble, tintColor: Color.SecondaryText }}
      title={loadError ? "Couldn't load status" : hasStatus ? current!.status_text || "(no text)" : "No status"}
      subtitle={loadError ?? (hasStatus ? current!.status_emoji : "")}
      accessories={hasStatus && expiry ? [{ text: expiry, icon: Icon.Clock }] : undefined}
      actions={
        <ActionPanel>
          <Action
            title="Set Custom Status"
            icon={Icon.Pencil}
            onAction={() => push(<CustomStatusForm onSubmit={applyStatus} />)}
          />
          {hasStatus && <Action title="Clear Status" icon={Icon.XMarkCircle} onAction={onClear} />}
          <Action
            title="Refresh"
            icon={Icon.ArrowClockwise}
            shortcut={{ modifiers: ["cmd"], key: "r" }}
            onAction={onRefresh}
          />
          <Action title="Open Extension Preferences" icon={Icon.Gear} onAction={openExtensionPreferences} />
        </ActionPanel>
      }
    />
  );
}

function PresetRow({
  preset,
  applyStatus,
  onClear,
  onRefresh,
}: {
  preset: Preset;
  applyStatus: (emoji: string, text: string, minutes: number) => Promise<void>;
  onClear: () => void;
  onRefresh: () => void;
}) {
  const { push } = useNavigation();
  return (
    <List.Item
      icon={emojiGlyph(preset.emoji)}
      title={preset.text}
      subtitle={durationLabel(preset.minutes)}
      keywords={[preset.emoji.replace(/:/g, "")]}
      actions={
        <ActionPanel>
          <Action
            title={`Set Status (${durationLabel(preset.minutes)})`}
            icon={Icon.CheckCircle}
            onAction={() => applyStatus(preset.emoji, preset.text, preset.minutes)}
          />
          <ActionPanel.Submenu title="Set Status with Duration…" icon={Icon.Clock}>
            {DURATION_OPTIONS.map((opt) => (
              <Action
                key={opt.minutes}
                title={opt.title}
                icon={Icon.Clock}
                onAction={() => applyStatus(preset.emoji, preset.text, opt.minutes)}
              />
            ))}
          </ActionPanel.Submenu>
          <Action
            title="Edit Before Setting…"
            icon={Icon.Pencil}
            shortcut={{ modifiers: ["cmd"], key: "e" }}
            onAction={() =>
              push(
                <CustomStatusForm
                  onSubmit={applyStatus}
                  initial={{ emoji: preset.emoji, text: preset.text, minutes: preset.minutes }}
                />,
              )
            }
          />
          <Action title="Clear Status" icon={Icon.XMarkCircle} onAction={onClear} />
          <Action
            title="Refresh"
            icon={Icon.ArrowClockwise}
            shortcut={{ modifiers: ["cmd"], key: "r" }}
            onAction={onRefresh}
          />
        </ActionPanel>
      }
    />
  );
}

function CustomStatusForm({
  onSubmit,
  initial,
}: {
  onSubmit: (emoji: string, text: string, minutes: number) => Promise<void>;
  initial?: { emoji: string; text: string; minutes: number };
}) {
  const { pop } = useNavigation();
  const defaultMinutes = initial?.minutes ?? 60;

  // Build emoji suggestions from the default+user presets so the dropdown stays
  // useful even if the user is editing a custom one-off status.
  const emojiSuggestions = Array.from(
    new Map(DEFAULT_PRESETS.map((p) => [p.emoji, p.emoji])).values(),
  );

  return (
    <Form
      navigationTitle="Set Custom Status"
      actions={
        <ActionPanel>
          <Action.SubmitForm
            title="Set Status"
            icon={Icon.CheckCircle}
            onSubmit={async (values: { emoji: string; text: string; minutes: string }) => {
              const minutes = Number.parseInt(values.minutes, 10) || 0;
              await onSubmit(values.emoji.trim(), values.text.trim(), minutes);
              pop();
            }}
          />
        </ActionPanel>
      }
    >
      <Form.TextField
        id="emoji"
        title="Emoji"
        placeholder=":airplane:"
        defaultValue={initial?.emoji ?? ":speech_balloon:"}
        info="Use the :code: form. Any custom Slack emoji code works too."
      />
      <Form.TextField id="text" title="Status" placeholder="Flying" defaultValue={initial?.text ?? ""} />
      <Form.Dropdown id="minutes" title="Clear After" defaultValue={String(defaultMinutes)}>
        {DURATION_OPTIONS.map((opt) => (
          <Form.Dropdown.Item key={opt.minutes} value={String(opt.minutes)} title={opt.title} />
        ))}
      </Form.Dropdown>
      <Form.Description
        text={
          emojiSuggestions.length
            ? `Tip: common codes — ${emojiSuggestions.slice(0, 6).join("  ")}`
            : "Tip: use :code: form for emoji."
        }
      />
    </Form>
  );
}
