#!/data/data/com.termux/files/usr/bin/bash
# Reconnector Backend Updater
# Run this on the tablet to pull the latest backend from GitHub.
# It downloads reconnector_api.py from the main branch, saves it with a unique
# version+timestamp name, and refreshes the latest.py symlink.
#
# Usage:
#   bash ~/reconnector/Backend/update_backend.sh
set -u

BOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BOT_DIR"

REMOTE="https://raw.githubusercontent.com/Faludaddd/Reconnector/main/Backend/reconnector_api.py"
TMP_FILE="$BOT_DIR/.download_tmp.py"

echo "[UPDATE] Downloading latest backend..."
if ! command -v curl >/dev/null 2>&1; then
    echo "[UPDATE] curl not found. Installing..."
    pkg install -y curl
fi

curl -fsSL -o "$TMP_FILE" "$REMOTE" || {
    echo "[UPDATE] FAILED: could not download $REMOTE"
    exit 1
}

# Extract version string from the file (e.g. "Reconnector API Server v6")
VERSION=$(grep -oE 'API Server v[0-9]+' "$TMP_FILE" | head -1 | grep -oE '[0-9]+')
[[ -z "$VERSION" ]] && VERSION="unknown"

STAMP=$(date +%y%m%d-%H%M)
NEW_NAME="reconnector_api_v${VERSION}_${STAMP}.py"

mv "$TMP_FILE" "$BOT_DIR/$NEW_NAME"
chmod +x "$BOT_DIR/$NEW_NAME"

# Refresh symlink so start_reconnector.sh picks up the newest file
# (it auto-discovers reconnector_api_v*.py, but we still symlink for clarity)
ln -sf "$BOT_DIR/$NEW_NAME" "$BOT_DIR/latest.py"

echo "[UPDATE] Saved as: $NEW_NAME"
echo "[UPDATE] Symlink: latest.py -> $NEW_NAME"

# List all installed versions (newest first)
echo ""
echo "[UPDATE] Installed backend versions:"
ls -1t "$BOT_DIR"/reconnector_api_v*.py 2>/dev/null | head -10

echo ""
echo "[UPDATE] Done. Restart the backend with:"
echo "  pkill -f reconnector_api"
echo "  bash ~/reconnector/Backend/start_reconnector.sh"
