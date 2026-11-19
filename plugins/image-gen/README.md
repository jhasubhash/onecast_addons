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
- Your last choices are remembered.
- Reopen ImageGen at any time to see what's queued, rendering, done or failed. Click a finished row to
  open it; hover for Copy, Show in Finder, Run Again (new seed) and Remove.
- **⌘K** has Cancel, Reuse Last Settings, Open Output Folder, Refresh Model List, Clear Finished and
  Open ComfyUI in Browser.
- **Qwen-Image-Edit** restyles or edits 1–3 reference images: drop them on the window, or select them
  in Finder before opening ImageGen.

## Models

ImageGen lists every image model under the models folder: Qwen-Image, Qwen-Image 2512 and
Qwen-Image-Edit (GGUF or safetensors), and SDXL / SDXL Turbo / SD 1.5 checkpoints. Video models are
left out. LoRAs show only for the base they were trained on, and styles come from the Jarvis
`looks.json` presets. A Qwen speed LoRA (Lightning) is used for Fast and Standard when present.

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
| `Comfy.swift` | The ComfyUI client (queue, progress websocket, history, upload, cancel) and the workflow graphs. |
| `Jobs.swift` | The background job queue, HUD progress, notifications, saving and history. |
| `Views.swift` | The launcher surface. |
| `ImageGen.swift` | The plugin entry point. |

Needs OneCast with the plugin HUD API (`showHUD`, `showHUDProgress`) and `pluginCloseLauncher`.
