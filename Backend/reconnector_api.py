"""
Reconnector API Server v10
- Single intelligent recovery flow (no multi-attempt logs)
- Smart watchdog state machine with ACTIVE re-confirmation burst
  (no more false restarts from flaky pidof reads)
- Stats persist across backend restarts with day-boundary resets
- Background-cached system info (battery/internet/temp/uptime) — status endpoint <100ms
- Stable log clearing
- All endpoints echo state for client confirmation
- Mandatory Bearer-token authentication on every request
- Crash classification: distinguishes kicks vs network drops
- screenrecord uses --size 1280x720 (native res fails on this tablet's encoder)
- Watchdog interval changes take effect within 5s (non-blocking sleep)
- Filename-randomized screenshot/video to avoid concurrent-request races
"""
import os, time, subprocess, json, re, logging, sys, base64, threading, uuid, secrets
from datetime import datetime
from logging.handlers import RotatingFileHandler
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn

PACKAGE = "com.roblox.client"
BASE_DIR = "/data/data/com.termux/files/home"
LOG_FILE = f"{BASE_DIR}/reconnector.log"
DISCONNECT_SIGNAL_FILE = "/sdcard/AE_disconnect_signal.txt"
STATS_FILE = f"{BASE_DIR}/.reconnector_stats.json"
HOST = "0.0.0.0"
PORT = 8080
DEFAULT_TIMEOUT = 15
API_KEY_FILE = f"{BASE_DIR}/.reconnector_api_key"


def _load_or_create_api_key():
    """Persistent random API key, generated once and reused across
    restarts. Every request must present it - without this, ANY device
    on the same network (or the internet, if this port is ever exposed
    beyond home WiFi, which is the explicit goal of the iOS app) could
    force-restart the bot, change the game link, toggle optimizations,
    or pull screenshots/video with zero authentication at all."""
    env_key = os.environ.get("RECONNECTOR_API_KEY", "").strip()
    if env_key:
        return env_key
    try:
        if os.path.exists(API_KEY_FILE):
            with open(API_KEY_FILE, 'r') as f:
                existing = f.read().strip()
            if existing:
                return existing
    except Exception:
        pass
    new_key = secrets.token_hex(24)
    try:
        with open(API_KEY_FILE, 'w') as f:
            f.write(new_key)
        os.chmod(API_KEY_FILE, 0o600)
    except Exception:
        pass
    return new_key


API_KEY = _load_or_create_api_key()

# How long after a reconnect before we trust Roblox is healthy.
POST_RECONNECT_GRACE_SEC = 60
# When a health check comes back "no live PID", we don't immediately declare
# death — we run an ACTIVE re-confirmation burst: this many checks, this many
# seconds apart. Only if ALL of them fail do we declare Roblox dead.
# This eliminates false restarts from flaky rish/pidof reads (which we proved
# earlier can return inconsistent output for the identical command back-to-back).
DEATH_CONFIRMATION_CHECKS = 3
DEATH_CONFIRMATION_INTERVAL_SEC = 5
# Legacy alias kept for any code that still references it.
DEATH_CONFIRMATION_SEC = DEATH_CONFIRMATION_CHECKS * DEATH_CONFIRMATION_INTERVAL_SEC
# Background refresh interval for slow system queries.
SYS_REFRESH_INTERVAL_SEC = 15

NETWORK_DROP_KEYWORDS = [
    "lost connection", "failed to connect", "connection lost",
    "the connection to the server was lost", "your connection has timed out",
    "reconnect unsuccessful",
]
KICK_KEYWORDS = [
    "you have been kicked", "please rejoin", "has been removed",
    "experience failed to load",
]
DISCONNECT_KEYWORDS = NETWORK_DROP_KEYWORDS + KICK_KEYWORDS + ["disconnected"]


def _classify_disconnect_text(text):
    """Which category a matched disconnect text actually belongs to, so
    stats aren't all lumped under 'kicks' regardless of actual cause."""
    lower = text.lower()
    for kw in KICK_KEYWORDS:
        if kw in lower:
            return "kicks"
    for kw in NETWORK_DROP_KEYWORDS:
        if kw in lower:
            return "network_drops"
    return "kicks"  # bare "disconnected" - ambiguous, default to kicks

logger = logging.getLogger("reconnector")
logger.setLevel(logging.INFO)
_fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s", "%H:%M:%S")
_sh = logging.StreamHandler(sys.stdout)
_sh.setFormatter(_fmt)
logger.addHandler(_sh)
try:
    _fh = RotatingFileHandler(LOG_FILE, maxBytes=2_000_000, backupCount=3)
    _fh.setFormatter(_fmt)
    logger.addHandler(_fh)
except Exception:
    pass


_stats_lock = threading.Lock()


def _today_str():
    """Local date string for day-boundary reset tracking."""
    return datetime.now().strftime("%Y-%m-%d")


def _load_persisted_stats():
    """Load stats from disk. Returns dict with 'date' and 'stats' keys, or fresh defaults."""
    try:
        if os.path.exists(STATS_FILE):
            with open(STATS_FILE, 'r') as f:
                data = json.load(f)
            today = _today_str()
            # Day-boundary reset: if the saved date is not today, zero out stats
            if data.get("date") != today:
                logger.info(f"[STATS] Day rollover detected ({data.get('date')} -> {today}), resetting stats")
                return {"date": today, "stats": {"crashes": 0, "kicks": 0, "network_drops": 0}}
            return data
    except Exception as e:
        logger.warning(f"[STATS] Failed to load persisted stats: {e}")
    return {"date": _today_str(), "stats": {"crashes": 0, "kicks": 0, "network_drops": 0}}


def _persist_stats_impl():
    """Save current stats to disk. Called after every state change."""
    with _stats_lock:
        try:
            data = {"date": _today_str(), "stats": dict(state.stats)}
            with open(STATS_FILE, 'w') as f:
                json.dump(data, f)
        except Exception as e:
            logger.warning(f"[STATS] Failed to persist stats: {e}")


def _check_day_rollover_impl():
    """If the date has changed since stats were last saved, reset to zero."""
    with _stats_lock:
        try:
            if os.path.exists(STATS_FILE):
                with open(STATS_FILE, 'r') as f:
                    data = json.load(f)
                if data.get("date") != _today_str():
                    logger.info(f"[STATS] Day rollover detected, resetting stats")
                    state.stats = {"crashes": 0, "kicks": 0, "network_drops": 0}
                    _persist_stats_impl()
        except Exception:
            pass


class State:
    current_game_link = "https://www.roblox.com/games/84515722934860/Anime-Expeditions"
    is_paused = False
    watchdog_enabled = True
    watchdog_interval_minutes = 1
    last_crash_reason = "-"
    bot_first_start_time = time.time()
    # State machine: unknown | launching | healthy | reconnecting | offline
    roblox_state = "unknown"
    last_reconnect_time = 0
    consecutive_ocr_hits = 0
    stats = {"crashes": 0, "kicks": 0, "network_drops": 0}
    reconnect_timestamps = []
    crash_log = []
    opt_kill_bg = False
    opt_process_limit = False
    opt_no_animations = False
    opt_force_gpu = False
    opt_no_bluetooth = False

    # Watchdog tracking
    last_pid_seen_time = time.time()
    last_lua_signal_time = 0
    recovery_in_progress = False

    # Cached system info (refreshed by background thread)
    cached_battery = -1
    cached_internet = False
    cached_cpu_temp = None
    cached_ram_total = None
    cached_ram_free = None
    cached_uptime = 0
    cached_brightness = 128


state = State()
reconnect_lock = threading.Lock()


def _persist_stats():
    """Public wrapper — save current stats to disk. Called after every state change."""
    _persist_stats_impl()


def _check_day_rollover():
    """Public wrapper — if the date has changed since stats were last saved, reset to zero."""
    _check_day_rollover_impl()


_state_lock = threading.Lock()


def _run_cmd(cmd, timeout=DEFAULT_TIMEOUT):
    try:
        result = subprocess.run(['rish', '-c', cmd], capture_output=True, text=True, timeout=timeout)
        return result.stdout.strip()
    except Exception:
        return ""


def get_roblox_pid():
    try:
        r = subprocess.run(['rish', '-c', f'pidof {PACKAGE}'],
                           capture_output=True, text=True, timeout=8)
        return r.stdout.strip()
    except Exception:
        return ""


def is_process_alive(pid_str):
    if not pid_str:
        return False
    try:
        for pid in pid_str.split():
            r = subprocess.run(['rish', '-c', f'cat /proc/{pid}/status 2>/dev/null | grep "^State:"'],
                               capture_output=True, text=True, timeout=3)
            s = r.stdout.strip()
            if s and "zombie" not in s.lower() and "dead" not in s.lower():
                return True
        return False
    except Exception:
        return False


def get_roblox_activity_state():
    """Returns: 'foreground' | 'background' | 'stopped' | 'unknown'."""
    try:
        r = subprocess.run(
            ['rish', '-c',
             f'dumpsys activity activities 2>/dev/null | grep -E "mResumedActivity|topResumedActivity|mFocusedActivity" | head -3'],
            capture_output=True, text=True, timeout=5)
        out = r.stdout.lower()
        if PACKAGE in out:
            return "foreground"
        r2 = subprocess.run(
            ['rish', '-c', f'dumpsys activity processes 2>/dev/null | grep -c "ProcessRecord.*{PACKAGE}"'],
            capture_output=True, text=True, timeout=5)
        if r2.stdout.strip() not in ("", "0"):
            return "background"
        return "stopped"
    except Exception:
        return "unknown"


# ---------------------------------------------------------------------------
# BACKGROUND SYSTEM INFO REFRESHER
# ---------------------------------------------------------------------------
def refresh_system_info_loop():
    """Refreshes slow system queries (battery, internet, temp, etc.) in background
    so the /api/status endpoint stays fast (<100ms)."""
    logger.info("[STARTUP] System info refresher started")
    while True:
        try:
            # Battery
            try:
                r = subprocess.run(['rish', '-c', 'dumpsys battery | grep level'],
                                   capture_output=True, text=True, timeout=5)
                for l in r.stdout.splitlines():
                    if l.strip().startswith("level:"):
                        try:
                            state.cached_battery = int(l.split(":")[1].strip())
                        except Exception:
                            pass
                        break
            except Exception:
                pass

            # Internet
            try:
                r = subprocess.run(['rish', '-c', 'ping -c 1 -W 3 8.8.8.8'],
                                   capture_output=True, text=True, timeout=6)
                state.cached_internet = (r.returncode == 0)
            except Exception:
                state.cached_internet = False

            # CPU temp
            try:
                r = subprocess.run(['rish', '-c', 'cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null'],
                                   capture_output=True, text=True, timeout=3)
                if r.stdout.strip():
                    state.cached_cpu_temp = int(r.stdout.strip()) / 1000.0
            except Exception:
                pass

            # RAM
            try:
                r = subprocess.run(['rish', '-c', 'cat /proc/meminfo | head -3'],
                                   capture_output=True, text=True, timeout=3)
                for l in r.stdout.splitlines():
                    if "MemTotal" in l:
                        state.cached_ram_total = int(l.split()[1]) // 1024
                    elif "MemFree" in l:
                        state.cached_ram_free = int(l.split()[1]) // 1024
            except Exception:
                pass

            # Uptime
            try:
                r = subprocess.run(['rish', '-c', 'cat /proc/uptime'],
                                   capture_output=True, text=True, timeout=3)
                if r.stdout.strip():
                    state.cached_uptime = int(float(r.stdout.split()[0]))
            except Exception:
                pass

            # Brightness
            try:
                r = subprocess.run(['rish', '-c', 'settings get system screen_brightness'],
                                   capture_output=True, text=True, timeout=3)
                val = r.stdout.strip()
                if val.isdigit():
                    state.cached_brightness = int(val)
            except Exception:
                pass

        except Exception as e:
            logger.error(f"[SYSREFRESH] Error: {e}")

        time.sleep(SYS_REFRESH_INTERVAL_SEC)


def capture_and_check_disconnect():
    """Returns the matched keyword text, or None if no disconnect text found."""
    img_path = "/sdcard/rbx_watchdog.png"
    text = _run_cmd(
        f'screencap -p {img_path} && magick {img_path} -gravity Center -crop 40x40%+0+0 -resize 480x '
        f'-colorspace Gray -threshold 50% png:- | tesseract stdin stdout --psm 3; rm -f {img_path}',
        timeout=20)
    lower = text.lower()
    for w in DISCONNECT_KEYWORDS:
        if w in lower:
            return w
    text2 = _run_cmd(
        f'screencap -p {img_path} && magick {img_path} -gravity Center -crop 40x40%+0+0 -resize 480x '
        f'-colorspace Gray -threshold 50% png:- | tesseract stdin stdout --psm 6; rm -f {img_path}',
        timeout=20)
    lower2 = text2.lower()
    for w in DISCONNECT_KEYWORDS:
        if w in lower2:
            return w
    return None


# ---------------------------------------------------------------------------
# OPTIMIZATIONS
# ---------------------------------------------------------------------------
def apply_optimization(name, enabled):
    if name == "kill_bg" and enabled:
        apps = ["com.android.chrome", "com.google.android.youtube", "com.spotify.music",
                "com.netflix.mediaclient", "com.facebook.katana", "com.instagram.android",
                "com.snapchat.android", "com.twitter.android", "com.discord", "com.whatsapp"]
        for app in apps:
            _run_cmd(f'am force-stop {app}', timeout=3)
        logger.info("[OPT] Killed background apps")
    elif name == "process_limit":
        _run_cmd(f'settings put global background_process_limit {"0" if enabled else "-1"}', timeout=3)
        logger.info(f"[OPT] Process limit {'set to 0' if enabled else 'restored'}")
    elif name == "no_animations":
        val = "0" if enabled else "1"
        _run_cmd(f'settings put global window_animation_scale {val}', timeout=3)
        _run_cmd(f'settings put global transition_animation_scale {val}', timeout=3)
        _run_cmd(f'settings put global animator_duration_scale {val}', timeout=3)
        logger.info(f"[OPT] Animations {'disabled' if enabled else 'restored'}")
    elif name == "force_gpu":
        _run_cmd(f'settings put system debug.hwui.render {"1" if enabled else "false"}', timeout=3)
        logger.info(f"[OPT] Force GPU {'enabled' if enabled else 'disabled'}")
    elif name == "no_bluetooth":
        _run_cmd(f'svc bluetooth {"disable" if enabled else "enable"}', timeout=5)
        logger.info(f"[OPT] Bluetooth {'disabled' if enabled else 'enabled'}")


# ---------------------------------------------------------------------------
# SINGLE INTELLIGENT RECOVERY FLOW
# No multi-attempt logs. One workflow. Only meaningful events are logged.
# ---------------------------------------------------------------------------
def reconnect_game(reason="unknown"):
    with reconnect_lock:
        # Prevent overlapping recovery attempts
        if state.recovery_in_progress:
            logger.info("[RECONNECT] Already in progress, skipping")
            return False
        # Skip if we just reconnected (within 45s)
        recent = [t for t in state.reconnect_timestamps if time.time() - t < 45]
        if recent:
            logger.info("[RECONNECT] Recent reconnect, skipping")
            return False

        state.recovery_in_progress = True
        state.reconnect_timestamps.append(time.time())
        state.stats["crashes"] += 1
        state.last_crash_reason = reason
        _set_state("reconnecting")
        state.crash_log.insert(0, {"timestamp": int(time.time()), "reason": reason})
        if len(state.crash_log) > 50:
            state.crash_log = state.crash_log[:50]
        _persist_stats()

        logger.info(f"[RECONNECT] Reconnect started. Reason: {reason}")
        m = re.search(r'/games/(\d+)', state.current_game_link)
        launch_url = f"roblox://placeId={m.group(1)}" if m else state.current_game_link

        success = _perform_recovery(launch_url)

        state.consecutive_ocr_hits = 0
        state.last_reconnect_time = time.time()
        state.recovery_in_progress = False

        if success:
            _set_state("launching")
            logger.info("[RECONNECT] Reconnect complete. Roblox detected.")
        else:
            _set_state("offline")
            logger.error("[RECONNECT] Reconnect failed.")
        return success


def _perform_recovery(launch_url):
    """Single recovery workflow. Internal validation only — no attempt-counter logs."""
    # 1. Force-stop
    logger.info("[RECONNECT] Force-stopping Roblox.")
    _run_cmd(f'am force-stop {PACKAGE}')
    time.sleep(1.5)

    # 2. Kill any leftover PID
    pid = get_roblox_pid()
    if pid:
        _run_cmd(f'kill -9 {pid.split()[0]}')
        time.sleep(1)

    # 3. Launch via deep link
    logger.info("[RECONNECT] Launching Roblox.")
    _run_cmd(f'am start -a android.intent.action.VIEW -d "{launch_url}"')

    # 4. Wait for Roblox to come up — smart polling with multi-signal validation
    logger.info("[RECONNECT] Waiting for Roblox to launch.")
    deadline = time.time() + 35
    time.sleep(3)  # initial settle
    while time.time() < deadline:
        new_pid = get_roblox_pid()
        if new_pid and is_process_alive(new_pid):
            # Confirm via activity manager — Roblox must actually be a real process
            act_state = get_roblox_activity_state()
            if act_state in ("foreground", "background"):
                return True
        time.sleep(2)

    return False


def _set_state(new_state):
    with _state_lock:
        if state.roblox_state != new_state:
            state.roblox_state = new_state


# ---------------------------------------------------------------------------
# 3-SECOND VIDEO
# ---------------------------------------------------------------------------
def record_3s_video():
    video_path = "/sdcard/rbx_3s_video.mp4"
    _run_cmd(f'rm -f {video_path}')
    logger.info("[VIDEO] Recording 3-second video...")
    # --size 1280x720 is required on this device: native resolution
    # (1920x1200) fails to allocate the hardware encoder (err=-12) and
    # screenrecord exits instantly with no output file at all - confirmed
    # by direct on-device testing, not a guess.
    result = _run_cmd(f'screenrecord --time-limit 3 --size 1280x720 {video_path}', timeout=18)
    if not os.path.exists(video_path):
        logger.error(f"[VIDEO] No output file produced. screenrecord output: {result[:300]!r}")
        return ""
    size = os.path.getsize(video_path)
    if size < 15000:
        logger.error(f"[VIDEO] Output too small ({size} bytes) - likely incomplete")
        _run_cmd(f'rm -f {video_path}')
        return ""
    try:
        with open(video_path, 'rb') as f:
            video_data = base64.b64encode(f.read()).decode('utf-8')
        _run_cmd(f'rm -f {video_path}')
        logger.info(f"[VIDEO] Recorded ({size} bytes raw, {len(video_data)} bytes b64)")
        return video_data
    except Exception as e:
        logger.error(f"[VIDEO] Read failed: {e}")
        return ""


# ---------------------------------------------------------------------------
# LOG CLEARING
# ---------------------------------------------------------------------------
def clear_logs():
    try:
        for h in list(logger.handlers):
            if isinstance(h, RotatingFileHandler):
                h.acquire()
                try:
                    h.flush()
                    h.close()
                finally:
                    h.release()
                logger.removeHandler(h)
        try:
            with open(LOG_FILE, 'w'):
                pass
        except Exception:
            pass
        for i in range(1, 4):
            try:
                if os.path.exists(f"{LOG_FILE}.{i}"):
                    os.remove(f"{LOG_FILE}.{i}")
            except Exception:
                pass
        try:
            new_fh = RotatingFileHandler(LOG_FILE, maxBytes=2_000_000, backupCount=3)
            new_fh.setFormatter(_fmt)
            logger.addHandler(new_fh)
        except Exception:
            pass
        logger.info("[LOGS] Cleared by user request")
        return True
    except Exception as e:
        print(f"[clear_logs] error: {e}", file=sys.stderr)
        return False


# ---------------------------------------------------------------------------
# SMART WATCHDOG — STATE MACHINE
# Distinguishes: launching | healthy | transitioning | closing | crashed
# ---------------------------------------------------------------------------
def _is_roblox_confirmed_alive():
    """Quick single-check: is Roblox definitely alive right now?
    Returns True only if BOTH the PID exists AND the activity manager knows about it.
    Used by the re-confirmation burst — one False here doesn't mean death, it just
    means 'this single check couldn't confirm life'."""
    pid = get_roblox_pid()
    if not pid:
        return False
    if not is_process_alive(pid):
        return False
    activity_state = get_roblox_activity_state()
    return activity_state in ("foreground", "background")


def evaluate_roblox_health():
    """Returns (action_needed: bool, reason: str).

    State machine logic:
    - Lua signal → immediate recovery
    - In post-reconnect grace → healthy
    - Recovery in progress → skip
    - Both PID + activity alive → check OCR for disconnect text
    - Not confirmed alive → ACTIVE re-confirmation burst:
        run DEATH_CONFIRMATION_CHECKS checks, DEATH_CONFIRMATION_INTERVAL_SEC apart.
        If ANY check confirms life, abort the burst and return healthy.
        Only if ALL checks fail do we declare Roblox dead.
      This eliminates false restarts from flaky rish/pidof reads.
    """
    # Signal 1: Lua disconnect file (highest priority)
    try:
        if os.path.exists(DISCONNECT_SIGNAL_FILE):
            with open(DISCONNECT_SIGNAL_FILE, 'r') as f:
                signal = f.read().strip()
            os.remove(DISCONNECT_SIGNAL_FILE)
            state.last_lua_signal_time = time.time()
            logger.warning(f"[WATCHDOG] Lua disconnect signal: {signal[:80]}")
            return True, "lua_disconnect_signal"
    except Exception:
        pass

    # If recovery is in progress, do nothing
    if state.recovery_in_progress:
        return False, "recovery_in_progress"

    # In post-reconnect grace — give Roblox time to settle
    if state.last_reconnect_time > 0 and time.time() - state.last_reconnect_time < POST_RECONNECT_GRACE_SEC:
        return False, "in_grace"

    # Gather signals
    pid = get_roblox_pid()
    pid_alive = bool(pid) and is_process_alive(pid)
    if pid_alive:
        state.last_pid_seen_time = time.time()

    activity_state = get_roblox_activity_state()

    # CASE A: Roblox is fully alive (PID + activity both agree)
    if pid_alive and activity_state in ("foreground", "background"):
        if activity_state == "foreground":
            matched = capture_and_check_disconnect()
            if matched:
                state.consecutive_ocr_hits += 1
                logger.warning(f"[WATCHDOG] Disconnect text (consecutive: {state.consecutive_ocr_hits}): {matched!r}")
                if state.consecutive_ocr_hits >= 2:
                    state.consecutive_ocr_hits = 0
                    category = _classify_disconnect_text(matched)
                    state.stats[category] += 1
                    _persist_stats()
                    return True, f"ocr_disconnect_{category}"
            else:
                state.consecutive_ocr_hits = 0
        _set_state("healthy")
        return False, "healthy"

    # CASE B: Not confirmed alive on this single check.
    # Don't immediately declare death — run an ACTIVE re-confirmation burst.
    # rish/pidof have been observed to return inconsistent output for the
    # identical command across back-to-back calls, so one miss is not enough.
    logger.info(f"[WATCHDOG] Initial check inconclusive (pid={pid_alive}, act={activity_state}) — starting re-confirmation burst")
    for i in range(DEATH_CONFIRMATION_CHECKS):
        time.sleep(DEATH_CONFIRMATION_INTERVAL_SEC)
        if _is_roblox_confirmed_alive():
            state.last_pid_seen_time = time.time()
            logger.info(f"[WATCHDOG] Re-confirmation burst check {i+1}/{DEATH_CONFIRMATION_CHECKS} — Roblox is alive (false alarm avoided)")
            _set_state("healthy")
            return False, "healthy"
        logger.info(f"[WATCHDOG] Re-confirmation burst check {i+1}/{DEATH_CONFIRMATION_CHECKS} — still no live PID")

    # All re-confirmation checks failed — Roblox is genuinely dead
    logger.warning(f"[WATCHDOG] Roblox confirmed closed after {DEATH_CONFIRMATION_CHECKS} re-confirmation checks (activity={activity_state})")
    return True, "process_closed"


def watchdog_loop():
    logger.info("[STARTUP] Watchdog started (smart state machine)")
    last_check = 0
    while True:
        time.sleep(5)
        interval_sec = max(30, state.watchdog_interval_minutes * 60)
        if time.time() - last_check < interval_sec:
            continue
        last_check = time.time()
        if not state.watchdog_enabled:
            continue
        try:
            action_needed, reason = evaluate_roblox_health()
            if action_needed:
                reconnect_game(reason=reason)
        except Exception as e:
            logger.error(f"[WATCHDOG] Error: {e}")


def fast_disconnect_checker():
    """Fast 5s loop — only handles Lua signals and OCR. Doesn't trigger on PID alone."""
    logger.info("[STARTUP] Fast checker active (5s)")
    while True:
        time.sleep(5)
        if not state.watchdog_enabled:
            continue
        if state.recovery_in_progress:
            continue
        if state.last_reconnect_time > 0 and time.time() - state.last_reconnect_time < POST_RECONNECT_GRACE_SEC:
            continue
        try:
            # Lua signal
            if os.path.exists(DISCONNECT_SIGNAL_FILE):
                with open(DISCONNECT_SIGNAL_FILE, 'r') as f:
                    signal = f.read().strip()
                os.remove(DISCONNECT_SIGNAL_FILE)
                state.last_lua_signal_time = time.time()
                logger.warning(f"[FAST] Lua disconnect: {signal[:80]}")
                reconnect_game(reason="lua_disconnect_signal")
                continue

            # Only run OCR if Roblox is in foreground
            pid = get_roblox_pid()
            if not pid or not is_process_alive(pid):
                continue
            if get_roblox_activity_state() != "foreground":
                continue

            matched = capture_and_check_disconnect()
            if matched:
                state.consecutive_ocr_hits += 1
                if state.consecutive_ocr_hits >= 2:
                    category = _classify_disconnect_text(matched)
                    logger.warning(f"[FAST] 2 consecutive OCR hits ({category}) — reconnecting")
                    state.stats[category] += 1
                    _persist_stats()
                    reconnect_game(reason=f"ocr_disconnect_fast_{category}")
                    state.consecutive_ocr_hits = 0
            else:
                state.consecutive_ocr_hits = 0
        except Exception as e:
            logger.error(f"[FAST] Error: {e}")


# ---------------------------------------------------------------------------
# STATUS — now FAST because all slow queries are cached
# ---------------------------------------------------------------------------
_cache = {"data": None, "ts": 0}


def get_status_dict():
    now = time.time()
    if _cache["data"] and (now - _cache["ts"]) < 2:
        return _cache["data"]
    data = {
        "roblox_state": state.roblox_state,
        "roblox_running": bool(get_roblox_pid()),
        "battery": state.cached_battery,
        "cpu_temp": state.cached_cpu_temp,
        "ram_total": state.cached_ram_total,
        "ram_free": state.cached_ram_free,
        "uptime": state.cached_uptime,
        "internet": state.cached_internet,
        "crashes_today": state.stats["crashes"],
        "kicks_today": state.stats["kicks"],
        "network_drops": state.stats["network_drops"],
        "watchdog_enabled": state.watchdog_enabled,
        "is_paused": state.is_paused,
        "interval": state.watchdog_interval_minutes,
        "game_link": state.current_game_link,
        "brightness": state.cached_brightness,
        "last_crash_reason": state.last_crash_reason,
        "last_reconnect": int(state.last_reconnect_time) if state.last_reconnect_time else 0,
        "bot_uptime": int(now - state.bot_first_start_time),
        "optimizations": {
            "kill_bg": state.opt_kill_bg,
            "process_limit": state.opt_process_limit,
            "no_animations": state.opt_no_animations,
            "force_gpu": state.opt_force_gpu,
            "no_bluetooth": state.opt_no_bluetooth,
        }
    }
    _cache["data"] = data
    _cache["ts"] = now
    return data


# ---------------------------------------------------------------------------
# HTTP SERVER
# ---------------------------------------------------------------------------
class RequestHandler(BaseHTTPRequestHandler):
    def _send_json(self, data, code=200):
        try:
            self.send_response(code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
            self.send_header('Access-Control-Allow-Headers', 'Content-Type, Authorization')
            self.end_headers()
            self.wfile.write(json.dumps(data).encode('utf-8'))
        except Exception:
            pass

    def _read_body(self):
        length = int(self.headers.get('Content-Length', 0))
        if length > 0:
            try:
                return json.loads(self.rfile.read(length).decode('utf-8'))
            except Exception:
                return {}
        return {}

    def _authorized(self):
        auth = self.headers.get('Authorization', '')
        presented = auth[7:] if auth.startswith('Bearer ') else auth
        return secrets.compare_digest(presented, API_KEY)

    def do_OPTIONS(self):
        self._send_json({"status": "ok"})

    def do_GET(self):
        path = self.path.split('?')[0]
        if not self._authorized():
            self._send_json({"error": "Unauthorized"}, 401)
            return
        if path == '/api/status':
            self._send_json(get_status_dict())
        elif path == '/api/crashes':
            self._send_json({"crashes": state.crash_log[:20]})
        elif path == '/api/screenshot':
            img_path = f"/sdcard/rbx_manual_{uuid.uuid4().hex[:8]}.png"
            _run_cmd(f'screencap -p {img_path}')
            try:
                with open(img_path, 'rb') as f:
                    img_data = base64.b64encode(f.read()).decode('utf-8')
                self._send_json({"image": img_data, "error": None})
            except Exception as e:
                self._send_json({"image": "", "error": str(e)})
            finally:
                _run_cmd(f'rm -f {img_path}')
        elif path == '/api/video':
            video_data = record_3s_video()
            self._send_json({"video": video_data, "error": None if video_data else "Failed"})
        elif path == '/api/logs':
            try:
                with open(LOG_FILE, 'r') as f:
                    f.seek(0, 2)
                    size = f.tell()
                    f.seek(max(0, size - 64_000))
                    tail = f.read().splitlines()
                self._send_json({"logs": tail[-100:]})
            except Exception:
                self._send_json({"logs": []})
        elif path == '/api/clear-logs':
            ok = clear_logs()
            self._send_json({"status": "ok" if ok else "error"})
        else:
            self._send_json({"error": "Not found"}, 404)

    def do_POST(self):
        path = self.path.split('?')[0]
        if not self._authorized():
            self._send_json({"error": "Unauthorized"}, 401)
            return
        body = self._read_body()

        if path == '/api/restart':
            threading.Thread(target=reconnect_game, args=("manual_restart",), daemon=True).start()
            self._send_json({"status": "initiated", "estimated_seconds": 20})
        elif path == '/api/watchdog/toggle':
            state.watchdog_enabled = not state.watchdog_enabled
            logger.info(f"[WATCHDOG] Toggled -> {'ON' if state.watchdog_enabled else 'OFF'}")
            self._send_json({"status": "ok", "enabled": state.watchdog_enabled})
        elif path == '/api/clear-anti-loop':
            state.reconnect_timestamps = []
            state.is_paused = False
            logger.info("[ANTILOOP] Cleared by user")
            self._send_json({"status": "ok"})
        elif path.startswith('/api/interval/'):
            try:
                minutes = int(path.split('/')[-1])
                state.watchdog_interval_minutes = max(1, minutes)
                logger.info(f"[INTERVAL] Set to {state.watchdog_interval_minutes} min")
                self._send_json({"status": "ok", "interval": state.watchdog_interval_minutes})
            except Exception:
                self._send_json({"status": "error"}, 400)
        elif path == '/api/game-link':
            url = body.get('url', '').strip()
            if url:
                state.current_game_link = url
                logger.info(f"[GAMELINK] Updated -> {url}")
                self._send_json({"status": "ok", "game_link": state.current_game_link})
            else:
                self._send_json({"status": "error", "error": "empty url"}, 400)
        elif path.startswith('/api/optimize/'):
            name = path.split('/')[-1]
            enabled = bool(body.get('enabled', False))
            if name in ["kill_bg", "process_limit", "no_animations", "force_gpu", "no_bluetooth"]:
                setattr(state, f"opt_{name}", enabled)
                threading.Thread(target=apply_optimization, args=(name, enabled), daemon=True).start()
                self._send_json({
                    "status": "ok",
                    "applied": True,
                    "name": name,
                    "enabled": enabled,
                    "optimizations": {
                        "kill_bg": state.opt_kill_bg,
                        "process_limit": state.opt_process_limit,
                        "no_animations": state.opt_no_animations,
                        "force_gpu": state.opt_force_gpu,
                        "no_bluetooth": state.opt_no_bluetooth,
                    }
                })
            else:
                self._send_json({"error": "Unknown optimization"}, 404)
        else:
            self._send_json({"error": "Not found"}, 404)

    def log_message(self, format, *args):
        pass


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    logger.info("[STARTUP] Reconnector API v10 starting...")
    print("")
    print("=" * 60)
    print(f"  API KEY (put this in the iOS app's settings):")
    print(f"  {API_KEY}")
    print("=" * 60)
    print("")

    # Load persisted stats (with day-boundary reset) before anything else
    persisted = _load_persisted_stats()
    state.stats = persisted["stats"]
    logger.info(f"[STARTUP] Loaded stats: {state.stats}")

    # Start background system info refresher FIRST so status endpoint is fast
    threading.Thread(target=refresh_system_info_loop, daemon=True).start()
    # Give the refresher a moment to populate initial values
    time.sleep(2)
    threading.Thread(target=watchdog_loop, daemon=True).start()
    threading.Thread(target=fast_disconnect_checker, daemon=True).start()
    threading.Thread(target=day_rollover_loop, daemon=True).start()
    server = ThreadedHTTPServer((HOST, PORT), RequestHandler)
    logger.info(f"[STARTUP] Server running on http://{HOST}:{PORT}")
    logger.info("[STARTUP] All systems online.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("[SHUTDOWN] Stopped")
        server.shutdown()


def day_rollover_loop():
    """Check for date rollover every 5 minutes; reset stats if the day changed."""
    logger.info("[STARTUP] Day-rollover checker started (5 min interval)")
    while True:
        time.sleep(300)
        try:
            _check_day_rollover()
        except Exception as e:
            logger.error(f"[ROLLOVER] Error: {e}")


if __name__ == "__main__":
    main()
