# Audio Devices — an Onecast DockWidget

Shows the active headphones/speakers and microphone on the dock, and lets you switch either in
one click.

- **compact** — an output glyph over a microphone glyph. Each turns red when muted (or when no
  device is active). The output glyph follows the device: headphones for AirPods, Bluetooth and
  headsets, a display for HDMI, a laptop for the built-in speakers.
- **wide** — adds the name of the active output and input.
- **popover** — two sections, *Output* and *Input*. Each has a mute button, a volume slider and every
  device of that kind; click one to make it the system default (output also moves the alert/sound
  effects device). A **Sound Settings** link opens System Settings.

It listens to Core Audio, so plugging in a headset, connecting AirPods or changing the volume from
the menu bar shows on the tile at once; there is no polling and no preferences.

## Install

```sh
DEST="$HOME/Library/Application Support/com.onecast.app.dev/dockwidgets/audio-devices"
mkdir -p "$DEST" && cp manifest.json AudioDevicesWidget.swift "$DEST/"
```

or run **Reload DockWidgets**. Then add **Audio Devices** from the widget library in
**Settings → Docks**.
