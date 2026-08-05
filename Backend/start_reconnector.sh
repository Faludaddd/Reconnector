#!/data/data/com.termux/files/usr/bin/bash
# Reconnector API Launcher
set -u

BOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$BOT_DIR/../reconnector.log"

if [[ -f "$BOT_DIR/../.env" ]]; then
    set -a
    source "$BOT_DIR/../.env"
    set +a
fi

crash_count=0
while true; do
    python "$BOT_DIR/reconnector_api.py" 2>&1 | tee -a "$LOG_FILE"
    exit_code=${PIPESTATUS[0]}
    crash_count=$((crash_count + 1))

    if [[ $exit_code -eq 0 ]]; then break; fi

    delay=$(( 5 * (2 ** (crash_count - 1)) ))
    if [[ $delay -gt 60 ]]; then delay=60; fi
    echo "[restart in ${delay}s]"
    sleep "$delay"
done
