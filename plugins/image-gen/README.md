# ImageGen

Type a prompt, pick one of your local models, an aspect ratio and a few options, and press Return.
The launcher closes and the image renders in the background through ComfyUI. While it renders,
OneCast's HUD shows a pill with a filling ring and the time left (click it to cancel). When it's done,
the HUD says so and a card offers **Open** and **Show in Finder**.

## Using it

- **Return** generates; **⇧Return** adds a new line to the prompt.
- The chips pick the **model**, **aspect ratio** (1:1, 4:5, 9:16, 2:3, 3:4 and their landscape
  versions), **quality**, a **style** and how many images (1–4). **More** adds things to avoid, a fixed
  seed, a faster draft size and a LoRA with its strength.
- **Match Image 1** (top of the aspect menu, on by default) sizes an **Edit** to the closest preset to
  the first reference's shape, so the model edits that picture instead of redrawing it for another
  frame. Other modes, and runs without a reference, use the preset you last picked. For a face swap,
  put the picture to keep first and the face second.
- **Styles:** 36 built-in looks that work on every model (Cinematic, Photoreal, Film Noir, Anime,
  Watercolor, Pixel Art, Cyberpunk and more). Each adds words before and after your prompt and a few
  things to avoid. Your own styles come first: **⌘K › Edit Your Styles** opens `styles.json`, a list
  of `{"name", "before", "after", "avoid"}`; save it and choose Refresh Model List. Styles that need a
  LoRA show in their own section, only for the model they were made for.
- **Pop Out** (⌘K) opens ImageGen in its own window that stays up while you work; Return generates
  there too, without closing it.
- Your last choices are remembered.
- Reopen ImageGen at any time to see what's queued, rendering, done or failed. Click a finished row to
  open it; hover for Copy, Show in Finder, **Load** (puts the prompt, references and settings back in the form
  to edit, without running) and Remove.
- **⌘K** has Cancel, Reuse Last Settings, Open Output Folder, Refresh Model List, Clear Finished and
  Open ComfyUI in Browser.
- **Reference images:** click **Reference** (or the **+** tile), paste a picture with **⌘V** (a
  screenshot, Copy Image in a browser, or image files copied in Finder), drop files or browser images
  on the window, or select images in Finder before opening ImageGen. How they're used depends on the
  model:
  - **Edit** (Qwen-Image 2.1 up to 6, FLUX.1 Kontext up to 3): the prompt says what to change or how
    to combine them. One picture keeps its own size; several are drawn at the chosen ratio.
  - **Variation** (every other model): image-to-image from the first reference. **Change** sets how far
    it moves: low stays close, high only keeps the layout and colours.
  - **Style** and **Face** (SDXL, with IP-Adapter): borrow the reference's look and subject, or keep a
    person's face, in a new picture the prompt describes. **Strength** sets how much.

## Models

ImageGen lists every image model under the models folder:

| Model | Good for |
|---|---|
| Qwen-Image 2.1 | The newest Qwen: creates, and edits up to 6 references. Fast uses its 8-step LoRA. |
| Qwen-Image 2512, Qwen-Image | Detail and text; the LoRA looks. |
| FLUX.1 dev | Rich detail and lighting. |
| FLUX.1 schnell | Good images in 4 steps. |
| FLUX.1 Kontext | Edits 1–3 reference images. |
| SDXL (Juggernaut XI) | Photoreal and general; Style and Face references through IP-Adapter. |

Qwen-Image-Edit 2509 is only offered when Qwen-Image 2.1 isn't installed. SDXL checkpoints are found
by their contents, not their names. Video models are left out. LoRAs show only for the base they were
trained on, and LoRA styles come from the Jarvis `looks.json` presets (the clay looks are left out).
Qwen-Image 2.1 and FLUX.1 dev and Kontext are licensed for non-commercial use.

## Settings (Settings → Plugins → ImageGen)

| Setting | Default |
|---|---|
| Save images to | `~/Pictures/ImageGen` |
| Show progress in the HUD | on |
| Show a card when an image is ready | on |
| Close the launcher after Generate | on |
| Safe mode (adds explicit content to the negative prompt) | on |
| Save settings beside each image (`.json`) | off |
| ComfyUI models folder | `~/Documents/comfyui/models` |
| ComfyUI address | `http://127.0.0.1:8189` |
| Start ComfyUI with | `python3 -I ~/Developer/jarvis/engine/comfy.py serve` |

If ComfyUI isn't answering, ImageGen starts it with the command above and waits up to 4 minutes.
It also waits while a Jarvis video render holds the GPU memory.

## Files

| File | What it holds |
|---|---|
| `Catalog.swift` | Scans the models folder: models, LoRAs, styles, sizes and sampler plans per model family. |
| `Styles.swift` | The built-in looks, your `styles.json`, and the LoRA looks that are hidden. |
| `Comfy.swift` | The ComfyUI client (queue, progress websocket, history, upload, cancel) and the workflow graphs. |
| `Jobs.swift` | The background job queue, HUD progress, notifications, saving and history. |
| `Views.swift` | The launcher surface. |
| `ImageGen.swift` | The plugin entry point. |

Needs OneCast with the plugin HUD API (`showHUD`, `showHUDProgress`) and `pluginCloseLauncher`.

## Popped-out window

Popped out, ImageGen reads like a chat: each prompt is a bubble with its references, its images follow it
(click one to open it; right-click to copy it or use it as a reference), the newest is at the bottom, and the
prompt box, references and options sit at the bottom edge.
