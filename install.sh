#!/bin/bash
# Install the screenshot renamer for the current user.
#   ./install.sh                 # folder defaults to ~/Screenshot
#   ./install.sh ~/Desktop       # custom folder
set -eu

FOLDER="${1:-$HOME/Screenshot}"
SCRIPT="$HOME/bin/screenshot-rename.sh"
LABEL="com.$(id -un | tr -cd 'a-z0-9').screenshot-rename"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/screenshot-rename.err"
CONFIG="$HOME/.config/screenshot-rename.env"

HERE=$(cd "$(dirname "$0")" && pwd)

mkdir -p "$HOME/bin" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs" "$HOME/.config" "$FOLDER"
install -m 755 "$HERE/rename.sh" "$SCRIPT"

sed -e "s|__LABEL__|$LABEL|" \
    -e "s|__SCRIPT__|$SCRIPT|" \
    -e "s|__FOLDER__|$FOLDER|" \
    -e "s|__LOG__|$LOG|" \
    "$HERE/launchd/screenshot-rename.plist" > "$PLIST"
plutil -lint "$PLIST" >/dev/null

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

if [[ ! -f $CONFIG ]]; then
  cat > "$CONFIG" <<'EOF'
# Vision model used to describe new screenshots (OpenAI-compatible endpoint).
# Without these two values the script only adds the timestamp name.
API_BASE=
MODEL=
# Credential: either put the key here or keep it in Keychain.
# API_KEY=sk-...
# API_KEY_CMD="security find-generic-password -s my-service -a my-account -w"
EOF
  chmod 600 "$CONFIG"
  echo "created $CONFIG — fill in API_BASE and MODEL"
fi

echo "installed:"
echo "  script   $SCRIPT"
echo "  agent    $LABEL ($PLIST)"
echo "  folder   $FOLDER"
echo "  log      $HOME/Library/Logs/screenshot-rename.log"
