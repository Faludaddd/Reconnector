#!/data/data/com.termux/files/usr/bin/bash
# Reconnector API Launcher v4
# - Auto-discovers the newest installed reconnector_api_*.py file
# - Symlinks it to "latest.py" so the launcher always runs the newest version
# - Restart-on-crash with exponential backoff
set -u

BOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$BOT_DIR/../reconnector.log"

if [[ -f "$BOT_DIR/../.env" ]]; then
    set -a
    source "$BOT_DIR/../.env"
    set +a
fi

# Pick the newest version-named file (e.g. reconnector_api_v6.py)
# Falls back to reconnector_api.py if no version-named file exists yet.
NEWEST=""
for f in "$BOT_DIR"/reconnector_api_v*.py; do
    [[ -f "$f" ]] || continue
    NEWEST="$f"
done
[[ -z "$NEWEST" && -f "$BOT_DIR/reconnector_api.py" ]] && NEWEST="$BOT_DIR/reconnector_api.py"

if [[ -z "$NEWEST" ]]; then
    echo "[FATAL] No reconnector_api*.py found in $BOT_DIR"
    exit 1
fi

# Refresh the latest.py symlink so we can also see what's running
ln -sf "$NEWEST" "$BOT_DIR/latest.py"

echo "[LAUNCHER] Running: $NEWEST"
echo "[LAUNCHER] Symlink: $BOT_DIR/latest.py -> $NEWEST"

crash_count=0
while true; do
    python "$NEWEST" 2>&1 | tee -a "$LOG_FILE"
    exit_code=${PIPESTATUS[0]}
    crash_count=$((crash_count + 1))

    if [[ $exit_code -eq 0 ]]; then break; fi

    delay=$(( 5 * (2 ** (crash_count - 1)) ))
    if [[ $delay -gt 60 ]]; then delay=60; fi
    echo "[restart in ${delay}s]"
    sleep "$delay"
done
