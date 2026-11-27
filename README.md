# auto-rename-screenshot

macOS screenshots get named `Screenshot 2026-11-27 at 23.16.08.png`. This renames them to what the picture actually shows:

```
Screenshot 2026-11-27 at 23.16.08.png
  → 2026-11-27_23.16.08.png                      (instant, sortable)
  → 9router-usage-analytics.png                  (a few seconds later, from a vision model)
```

No Shortcuts, no Apple Intelligence. A launchd agent watches the screenshot folder and calls a vision model through any OpenAI-compatible endpoint.

## Why not Shortcuts

The `Use Model` action in Shortcuts only accepts text on the current on-device model, so image descriptions fail with *"The model cannot provide a response for this request"*. macOS Shortcuts also has no folder-change trigger. launchd covers both.

## How it works

1. **Stage 1** — every new `Screenshot YYYY-MM-DD at HH.MM.SS.png` is renamed to `YYYY-MM-DD_HH.MM.SS.png`, so files sort chronologically even before the model answers.
2. **Stage 2** — the file is downscaled to a 1024 px JPEG (~120 KB), sent to the configured model, and the answer becomes the filename: `<three-to-five-words>.png`.
3. Failures keep the timestamp name. Files already processed carry the extended attribute `com.ammar.enriched`, so nothing is described twice.

Only screenshots newer than 15 minutes are described; older files in the folder are left alone. Change `ENRICH_MAX_AGE` in the script to widen that window.

## Requirements

- macOS (tested on 26.x, Apple silicon)
- `bash`, `sips`, `python3`, `curl` — all ship with macOS
- A vision-capable model behind an OpenAI-compatible `/chat/completions` endpoint

## Install

```bash
git clone https://github.com/AmmarArief/auto-rename-screenshot
cd auto-rename-screenshot
./install.sh                 # watches ~/Screenshot
# or: ./install.sh ~/Desktop
```

Then edit `~/.config/screenshot-rename.env`:

```bash
API_BASE=https://your-endpoint/v1
MODEL=your-vision-model
API_KEY=sk-...                                   # or:
# API_KEY_CMD="security find-generic-password -s my-service -a my-account -w"
```

Without `API_BASE` and `MODEL` the script still does stage 1 (timestamp names) and skips the model.

Point macOS at the same folder, otherwise nothing lands there:

```bash
mkdir -p ~/Screenshot
defaults write com.apple.screencapture location ~/Screenshot
killall SystemUIServer
```

## Verify

```bash
# create a screenshot, then watch the log
tail -f ~/Library/Logs/screenshot-rename.log
```

Expected lines:

```
renamed: Screenshot 2026-11-27 at 23.20.00.png -> 2026-11-27_23.20.00.png
enriched: discord-server-voice-connected.png
```

## Files

| Path | Purpose |
|---|---|
| `rename.sh` | the renamer (installed to `~/bin/screenshot-rename.sh`) |
| `launchd/screenshot-rename.plist` | agent template, filled in by `install.sh` |
| `install.sh` | installs script, agent, and a config stub |

## Tuning

- **Naming accuracy** comes from the prompt in `rename.sh`: it tells the model to transcribe text that is actually on screen, never invent a product name, and skip generic words (`screenshot`, `interface`, `desktop`).
- **Speed vs. cost**: lower `-Z 1024` to send smaller images, raise it when small UI text gets misread.
- **Latency**: naming takes a few seconds; reasoning models take longer. The timestamp name is already applied, so the rename is never blocked.

## Uninstall

```bash
launchctl bootout "gui/$(id -u)/com.$(id -un).screenshot-rename"
rm ~/Library/LaunchAgents/com.$(id -un).screenshot-rename.plist \
   ~/bin/screenshot-rename.sh ~/.config/screenshot-rename.env
```

## License

MIT
