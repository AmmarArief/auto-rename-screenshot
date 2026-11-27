#!/bin/bash
# Two-stage screenshot renamer.
#   Stage 1: "Screenshot 2026-11-27 at 10.11.12.png" -> "2026-11-27_10.11.12.png" (instant)
#   Stage 2: describe it with a vision model -> "login-page-error.png"
# Stage 2 skips files already enriched (extended attribute) or older than ENRICH_MAX_AGE.
# Runs under /bin/bash 3.2 (macOS default), so no mapfile, no ${var,,}.
set -u

export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

DIR="${SCREENSHOT_DIR:-$HOME/Screenshot}"
LOG="$HOME/Library/Logs/screenshot-rename.log"
LOCKDIR="$HOME/Library/Logs/.screenshot-rename.lockdir"
XATTR="com.ammar.enriched"
ENRICH_MAX_AGE="${ENRICH_MAX_AGE:-900}"
API_BASE="${API_BASE:-}"
MODEL="${MODEL:-}"

CONFIG="$HOME/.config/screenshot-rename.env"
[[ -f $CONFIG ]] && . "$CONFIG"

mkdir -p "$(dirname "$LOG")" "$DIR"

if ! mkdir "$LOCKDIR" 2>/dev/null; then
  holder=$(cat "$LOCKDIR/pid" 2>/dev/null)
  age=$(( $(date +%s) - $(stat -f%m "$LOCKDIR" 2>/dev/null || date +%s) ))
  if [[ -n $holder ]] && kill -0 "$holder" 2>/dev/null && (( age < 180 )); then
    exit 0
  fi
  rm -rf "$LOCKDIR"
  mkdir "$LOCKDIR" 2>/dev/null || exit 0
fi
echo $$ > "$LOCKDIR/pid"
trap 'rm -rf "$LOCKDIR" 2>/dev/null' EXIT

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

slugify() {
  tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9\n' '-' \
    | sed -e 's/-\{2,\}/-/g;' -e 's/^-//' -e 's/-$//' \
    | tr '-' '\n' \
    | grep -v '^$' \
    | grep -vxE 'screenshot|screen|screens|interface|desktop|computer|image|images|picture|window|monitor' \
    | paste -sd- - \
    | sed -e 's/^-//' -e 's/-$//' \
    | awk -F- '{out=""; for(i=1;i<=NF;i++){ w=$i; if (length(out)+length(w)+1>52) break; out=out (out?"-":"") w } print out }'
}

api_key() {
  if [[ -n ${API_KEY:-} ]]; then
    printf '%s' "$API_KEY"
  elif [[ -n ${API_KEY_CMD:-} ]]; then
    eval "$API_KEY_CMD" 2>/dev/null
  else
    security find-generic-password -s "${KEYCHAIN_SERVICE:-omp-9router}" -a "${KEYCHAIN_ACCOUNT:-9router}" -w 2>/dev/null
  fi
}

enrich() {
  local f=$1 base age key jpg payload resp slug target n attempt

  [[ -f $f ]] || return 0
  [[ -n ${API_BASE:-} && -n ${MODEL:-} ]] || return 0
  xattr -p "$XATTR" "$f" >/dev/null 2>&1 && return 0

  age=$(( $(date +%s) - $(stat -f%m "$f" 2>/dev/null || echo 0) ))
  if (( age > ENRICH_MAX_AGE )); then
    xattr -w "$XATTR" skipped-old "$f" 2>/dev/null
    return 0
  fi

  key=$(api_key)
  if [[ -z $key ]]; then
    log "no api key, skipped: $(basename "$f")"
    return 0
  fi

  jpg=$(mktemp -t ssr).jpg
  payload=$(mktemp -t ssr).json
  if ! sips -Z 1024 -s format jpeg -s formatOptions 75 "$f" --out "$jpg" >/dev/null 2>&1; then
    rm -f "$jpg" "$payload"
    return 0
  fi

  python3 - "$jpg" "$MODEL" > "$payload" <<'PY'
import base64, json, sys
b = base64.b64encode(open(sys.argv[1], 'rb').read()).decode()
print(json.dumps({
    "model": sys.argv[2],
    "messages": [{"role": "user", "content": [
        {"type": "text", "text": "Name this image as a filename: 3-5 lowercase English words joined by hyphens. Read the text that is actually on screen and use it: the window title, page heading, product name, URL or sidebar label. Transcribe those names exactly as spelled; never guess a name that is not visible. Then add the screen or panel being shown. Never use generic words like screenshot, screen, interface, desktop, computer or image. Output only the words, no punctuation, no extension."},
        {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + b}},
    ]}],
    "max_tokens": 1024,
}))
PY

  slug=""
  for attempt in 1 2; do
    resp=$(curl -s -m 45 "$API_BASE/chat/completions" \
      -H "Authorization: Bearer $key" -H "Content-Type: application/json" \
      -d @"$payload" 2>/dev/null)
    slug=$(printf '%s' "$resp" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin)["choices"][0]["message"]["content"])
except Exception:
    print("")
' 2>/dev/null | slugify)
    [[ -n $slug ]] && break
    sleep 2
  done

  rm -f "$jpg" "$payload"

  if [[ -z $slug ]]; then
    # No marker on failure: the next run retries while the file is still fresh.
    log "enrich failed: $(basename "$f")"
    return 0
  fi

  target="$DIR/${slug}.png"
  n=2
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

# Stage 1: localised screenshot names -> sortable timestamp.
for f in "$DIR"/Screenshot\ *.png; do
  name=$(basename "$f")
  [[ $name =~ ^[^0-9]*([0-9]{4}-[0-9]{2}-[0-9]{2})[[:space:]]+[^0-9]*[[:space:]]*([0-9]{2})\.([0-9]{2})\.([0-9]{2})\.png$ ]] || continue

  stamp="${BASH_REMATCH[1]}_${BASH_REMATCH[2]}.${BASH_REMATCH[3]}.${BASH_REMATCH[4]}"
  target="$DIR/$stamp.png"

  s1=$(stat -f%z "$f" 2>/dev/null || echo 0)
  sleep 0.4
  s2=$(stat -f%z "$f" 2>/dev/null || echo 0)
  [[ $s1 == "$s2" && $s1 != 0 ]] || continue

  n=2
  while [[ -e $target ]]; do
    target="$DIR/$stamp-$n.png"
    n=$((n + 1))
  done

  if mv -n "$f" "$target" 2>/dev/null; then
    log "renamed: $name -> $(basename "$target")"
    enrich "$target"
  fi
done

# Stage 2 catch-up for files an earlier run renamed but could not describe.
recent=$(ls -t "$DIR"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9].[0-9][0-9].[0-9][0-9].png 2>/dev/null | head -2)
if [[ -n $recent ]]; then
  while IFS= read -r f; do
    [[ -n $f ]] && enrich "$f"
  done <<< "$recent"
fi
