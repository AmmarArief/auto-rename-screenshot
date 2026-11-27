#!/bin/bash
# Two-stage screenshot renamer.
#   Stage 1: "Screenshot 2026-11-27 at 10.11.12.png" -> "2026-11-27_10.11.12.png" (instant)
#   Stage 2: enrich with a descriptive slug from a vision model -> "2026-11-27_10.11.12_login-page-error.png"
# Stage 2 is skipped for files that are already enriched (xattr) or older than ENRICH_MAX_AGE seconds.
# Called by launchd (WatchPaths) on every change to the folder; safe to run repeatedly.
set -u

DIR="${SCREENSHOT_DIR:-$HOME/Screenshot}"
LOG="$HOME/Library/Logs/screenshot-rename.log"
ENRICH_MAX_AGE="${ENRICH_MAX_AGE:-900}"   # only describe screenshots taken in the last 15 minutes
API_BASE="${API_BASE:-}"
MODEL="${MODEL:-}"
XATTR="com.ammar.enriched"

mkdir -p "$(dirname "$LOG")"
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Optional config: ~/.config/screenshot-rename.env
#   API_BASE=https://your-openai-compatible-endpoint/v1
#   MODEL=your-vision-model
#   API_KEY=sk-...            (or API_KEY_CMD="security find-generic-password ...")
CONFIG="$HOME/.config/screenshot-rename.env"
[[ -f $CONFIG ]] && . "$CONFIG"
LOCKDIR="$HOME/Library/Logs/.screenshot-rename.lockdir"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  # Holder may have died (SIGKILL skips the trap); take over only if its PID is gone.
  holder=$(cat "$LOCKDIR/pid" 2>/dev/null)
  if [[ -n $holder ]] && kill -0 "$holder" 2>/dev/null; then
    exit 0
  fi
  rmdir "$LOCKDIR" 2>/dev/null
  mkdir "$LOCKDIR" 2>/dev/null || exit 0
fi
echo $$ > "$LOCKDIR/pid"
trap 'rm -rf "$LOCKDIR" 2>/dev/null' EXIT

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

slugify() {
  tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9\n' '-' \
    | sed -e 's/-\{2,\}/-/g; s/^-//; s/-$//' \
    | tr '-' '\n' \
    | grep -vxE 'screenshot|screen|screens|interface|desktop|computer|image|images|picture|window|monitor' \
    | paste -sd- - \
    | sed -e 's/^-//; s/-$//' \
    | cut -c1-52
}

enrich() {
  local f=$1 base slug
  base=$(basename "$f" .png)

  if [[ -z ${API_BASE:-} || -z ${MODEL:-} ]]; then
    return 0
  fi
  if xattr -p "$XATTR" "$f" >/dev/null 2>&1; then
    return 0
  fi
  local age=$(( $(date +%s) - $(stat -f%m "$f") ))
  [[ $age -le $ENRICH_MAX_AGE ]] || { xattr -w "$XATTR" skipped-old "$f" 2>/dev/null; return 0; }

  local key
  if [[ -n ${API_KEY:-} ]]; then
    key=$API_KEY
  elif [[ -n ${API_KEY_CMD:-} ]]; then
    key=$(eval "$API_KEY_CMD" 2>/dev/null)
  else
    key=$(security find-generic-password -s "${KEYCHAIN_SERVICE:-omp-9router}" -a "${KEYCHAIN_ACCOUNT:-9router}" -w 2>/dev/null)
  fi
  [[ -n $key ]] || { log "no api key, skipped: $(basename "$f")"; xattr -w "$XATTR" no-key "$f" 2>/dev/null; return 0; }

  local jpg payload resp
  jpg=$(mktemp /tmp/ssr.XXXXXX.jpg)
  payload=$(mktemp /tmp/ssr.XXXXXX.json)
  sips -Z 1024 -s format jpeg -s formatOptions 75 "$f" --out "$jpg" >/dev/null 2>&1 || { rm -f "$jpg"; return 0; }

  python3 - "$jpg" "$MODEL" > "$payload" <<'PY'
import base64, json, sys
b = base64.b64encode(open(sys.argv[1], 'rb').read()).decode()
print(json.dumps({
    "model": sys.argv[2],
    "messages": [{"role": "user", "content": [
        {"type": "text", "text": "Name this image as a filename: 3-5 lowercase English words joined by hyphens. Read the text that is actually on screen and use it: the window title, page heading, product name, URL or sidebar label. Transcribe those names exactly as spelled; never guess a name that is not visible. Then add the screen or panel being shown. Never use generic words like screenshot, screen, interface, desktop, computer or image. Output only the words, no punctuation, no extension."},
        {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + b}},
    ]}],
    "max_tokens": 512,
}))
PY

  resp=$(curl -s -m 120 "$API_BASE/chat/completions" \
    -H "Authorization: Bearer $key" -H "Content-Type: application/json" \
    -d @"$payload" 2>/dev/null)
  rm -f "$jpg" "$payload"

  slug=$(printf '%s' "$resp" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d["choices"][0]["message"]["content"])
except Exception:
    print("")
' 2>/dev/null | slugify)

  if [[ -z $slug ]]; then
    log "enrich failed: $(basename "$f")"
    xattr -w "$XATTR" failed "$f" 2>/dev/null
    return 0
  fi

  local target="$DIR/${slug}.png"
  local n=2
  while [[ -e $target ]]; do
    target="$DIR/${slug}-${n}.png"
    n=$((n + 1))
  done

  if mv -n "$f" "$target" 2>/dev/null; then
    xattr -w "$XATTR" "$slug" "$target" 2>/dev/null
    log "enriched: $(basename "$target")"
  fi
}

shopt -s nullglob
fresh=()

# Stage 1: rename localised screenshot names to a sortable timestamp.
for f in "$DIR"/Screenshot\ *.png; do
  name=$(basename "$f")
  [[ $name =~ ^[^0-9]*([0-9]{4}-[0-9]{2}-[0-9]{2})[[:space:]]+[^0-9]*[[:space:]]*([0-9]{2})\.([0-9]{2})\.([0-9]{2})\.png$ ]] || continue

  target="$DIR/${BASH_REMATCH[1]}_${BASH_REMATCH[2]}.${BASH_REMATCH[3]}.${BASH_REMATCH[4]}.png"
  s1=$(stat -f%z "$f" 2>/dev/null || echo 0)
  sleep 0.4
  s2=$(stat -f%z "$f" 2>/dev/null || echo 0)
  [[ $s1 == "$s2" && $s1 != 0 ]] || continue

  n=2
  while [[ -e $target ]]; do
    target="$DIR/${BASH_REMATCH[1]}_${BASH_REMATCH[2]}.${BASH_REMATCH[3]}.${BASH_REMATCH[4]}-${n}.png"
    n=$((n + 1))
  done

  if mv -n "$f" "$target" 2>/dev/null; then
    log "renamed: $name -> $(basename "$target")"
    fresh+=("$target")
  fi
done

# Stage 2: describe fresh screenshots (and any timestamped file that is still recent).
for f in "$DIR"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9].[0-9][0-9].[0-9][0-9].png; do
  enrich "$f"
done
