"""
Reconnector API Server v7
- Smart multi-signal watchdog (PID + activity state + Lua signal + cooldown)
- Single-attempt reconnect with internal retries (cleaner log + UI)
- 3-second video (renamed from "proving")
- All endpoints echo state for client confirmation
- Stable log clearing
"""
import os, time, subprocess, json, re, logging, sys, base64, threading
from datetime import datetime
from logging.handlers import RotatingFileHandler
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn

PACKAGE = "com.roblox.client"
BASE_DIR = "/data/data/com.termux/files/home"
LOG_FILE = f"{BASE_DIR}/reconnector.log"
DISCONNECT_SIGNAL_FILE = "/sdcard/AE_disconnect_signal.txt"
HOST = "0.0.0.0"
PORT = 8080
DEFAULT_TIMEOUT = 15
POST_RECONNECT_COOLDOWN_SEC = 90
# Give Roblox this many seconds of "launching" grace before declaring it dead.
LAUNCH_GRACE_SEC = 45
# Consider Roblox healthy if it has been alive this long without crashing.
HEALTHY_SETTLE_SEC = 30

DISCONNECT_KEYWORDS = [
    "disconnected", "reconnect unsuccessful", "lost connection",
    "failed to connect", "connection lost", "you have been kicked",
    "please rejoin", "has been removed", "experience failed to load",
    "the connection to the server was lost", "your connection has timed out",
]

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


class State:
    current_game_link = "https://www.roblox.com/games/84515722934860/Anime-Expeditions"
    is_paused = False
    watchdog_enabled = True
    watchdog_interval_minutes = 1
    last_crash_reason = "-"
    bot_first_start_time = time.time()
    roblox_state = "unknown"  # unknown | healthy | loading | reconnecting | offline
    last_reconnect_time = 0
    last_state_change_time = time.time()
    consecutive_ocr_hits = 0
    stats = {"crashes": 0, "kicks": 0, "network_drops": 0}
    reconnect_timestamps = []
    crash_log = []
    opt_kill_bg = False
    opt_process_limit = False
    opt_no_animations = False
    opt_force_gpu = False
    opt_no_bluetooth = False
    brightness = 128
    # Multi-signal health tracker
    last_pid_seen_time = 0
    last_activity_alive_time = 0
    last_lua_signal_time = 0


state = State()
reconnect_lock = threading.Lock()
_health_lock = threading.Lock()


def _run_cmd(cmd, timeout=DEFAULT_TIMEOUT):
    try:
        result = subprocess.run(['rish', '-c', cmd], capture_output=True, text=True, timeout=timeout)
        return result.stdout.strip()
    except Exception:
        return ""


def get_battery():
    try:
        r = subprocess.run(['rish', '-c', 'dumpsys battery | grep level'],
                           capture_output=True, text=True, timeout=5)
        for l in r.stdout.splitlines():
            if l.strip().startswith("level:"):
                try:
                    return int(l.split(":")[1].strip())
                except Exception:
                    return -1
        return -1
    except Exception:
        return -1


def get_brightness():
    try:
        r = subprocess.run(['rish', '-c', 'settings get system screen_brightness'],
                           capture_output=True, text=True, timeout=3)
        val = r.stdout.strip()
        if val.isdigit():
            return int(val)
    except Exception:
        pass
    return state.brightness


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
    """Returns one of: 'foreground', 'background', 'stopped', 'unknown'.
    Uses ActivityManager to figure out what Roblox is actually doing —
    more reliable than PID alone during launches."""
    try:
        r = subprocess.run(
            ['rish', '-c',
             f'dumpsys activity activities | grep -E "mResumedActivity|topResumedActivity|mFocusedActivity" | head -3'],
            capture_output=True, text=True, timeout=5)
        out = r.stdout.lower()
        if PACKAGE in out:
            return "foreground"
        # Check if Roblox is at least running in any form
        r2 = subprocess.run(
            ['rish', '-c', f'dumpsys activity processes | grep -c "ProcessRecord.*{PACKAGE}"'],
            capture_output=True, text=True, timeout=5)
        if r2.stdout.strip() not in ("", "0"):
            return "background"
        return "stopped"
    except Exception:
        return "unknown"


def has_internet():
    try:
        r = subprocess.run(['rish', '-c', 'ping -c 1 -W 3 8.8.8.8'],
                           capture_output=True, text=True, timeout=6)
        return r.returncode == 0
    except Exception:
        return False


def get_system_info():
    info = {"cpu_temp": None, "ram_total": None, "ram_free": None, "uptime": None}
    try:
        r = subprocess.run(['rish', '-c', 'cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null'],
                           capture_output=True, text=True, timeout=3)
        if r.stdout.strip():
            info["cpu_temp"] = int(r.stdout.strip()) / 1000.0
    except Exception:
        pass
    try:
        r = subprocess.run(['rish', '-c', 'cat /proc/meminfo | head -3'],
                           capture_output=True, text=True, timeout=3)
        for l in r.stdout.splitlines():
            if "MemTotal" in l:
                info["ram_total"] = int(l.split()[1]) // 1024
            elif "MemFree" in l:
                info["ram_free"] = int(l.split()[1]) // 1024
    except Exception:
        pass
    try:
        r = subprocess.run(['rish', '-c', 'cat /proc/uptime'],
                           capture_output=True, text=True, timeout=3)
        if r.stdout.strip():
            info["uptime"] = int(float(r.stdout.split()[0]))
    except Exception:
        pass
    return info


def capture_and_check_disconnect():
    img_path = "/sdcard/rbx_watchdog.png"
    text = _run_cmd(
        f'screencap -p {img_path} && magick {img_path} -gravity Center -crop 40x40%+0+0 -resize 480x '
        f'-colorspace Gray -threshold 50% png:- | tesseract stdin stdout --psm 3; rm -f {img_path}',
        timeout=20)
    if any(w in text.lower() for w in DISCONNECT_KEYWORDS):
        return True
    text2 = _run_cmd(
        f'screencap -p {img_path} && magick {img_path} -gravity Center -crop 40x40%+0+0 -resize 480x '
        f'-colorspace Gray -threshold 50% png:- | tesseract stdin stdout --psm 6; rm -f {img_path}',
        timeout=20)
    return any(w in text2.lower() for w in DISCONNECT_KEYWORDS)


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
# RECONNECT — single clean attempt with internal retries.
# User-facing status changes only happen twice: reconnecting -> (healthy|offline).
# Internal attempts are logged but not surfaced as separate UI states.
# ---------------------------------------------------------------------------
def reconnect_game(reason="unknown"):
    with reconnect_lock:
        recent = [t for t in state.reconnect_timestamps if time.time() - t < 45]
        if recent:
            logger.info("[RECONNECTOR] Skipping — already in progress")
            return False

        state.reconnect_timestamps.append(time.time())
        state.stats["crashes"] += 1
        state.last_crash_reason = reason
        _set_state("reconnecting")
        state.crash_log.insert(0, {"timestamp": int(time.time()), "reason": reason})
        if len(state.crash_log) > 50:
            state.crash_log = state.crash_log[:50]

        logger.info(f"[RECONNECTOR] Trigger: {reason}")
        m = re.search(r'/games/(\d+)', state.current_game_link)
        launch_url = f"roblox://placeId={m.group(1)}" if m else state.current_game_link

        # Single user-visible attempt; up to 3 internal retries
        relaunched = False
        internal_delays = [0, 6, 10]
        for i, delay in enumerate(internal_delays):
            if delay > 0:
                logger.info(f"[RECONNECTOR] Internal retry {i + 1} after {delay}s")
                time.sleep(delay)
            else:
                logger.info(f"[RECONNECTOR] Starting recovery")

            # Force-stop
            _run_cmd(f'am force-stop {PACKAGE}')
            time.sleep(1.2)

            # Kill leftover PID
            pid = get_roblox_pid()
            if pid:
                _run_cmd(f'kill -9 {pid.split()[0]}')
                time.sleep(0.8)

            # Deep-link launch
            _run_cmd(f'am start -a android.intent.action.VIEW -d "{launch_url}"')

            # Wait for process with smart multi-signal polling
            deadline = time.time() + 25
            time.sleep(3)
            while time.time() < deadline:
                new_pid = get_roblox_pid()
                if new_pid and is_process_alive(new_pid):
                    # Confirm via activity manager that Roblox actually came up
                    act_state = get_roblox_activity_state()
                    if act_state in ("foreground", "background"):
                        relaunched = True
                        logger.info(f"[RECONNECTOR] Roblox live (PID {new_pid.split()[0]}, activity={act_state})")
                        break
                time.sleep(1.5)

            if relaunched:
                break

        state.consecutive_ocr_hits = 0
        state.last_reconnect_time = time.time()
        if relaunched:
            _set_state("loading")
            logger.info("[RECONNECTOR] Recovery complete — Roblox launching")
        else:
            _set_state("offline")
            logger.error("[RECONNECTOR] Recovery failed — Roblox offline")
        return relaunched


def _set_state(new_state):
    """Update roblox_state and track when it changed."""
    with _health_lock:
        if state.roblox_state != new_state:
            state.roblox_state = new_state
            state.last_state_change_time = time.time()


# ---------------------------------------------------------------------------
# 3-SECOND VIDEO
# ---------------------------------------------------------------------------
def record_3s_video():
    """Records a 3-second screen recording and returns base64 MP4."""
    video_path = "/sdcard/rbx_3s_video.mp4"
    _run_cmd(f'rm -f {video_path}')
    logger.info("[VIDEO] Recording 3-second video...")
    _run_cmd(f'screenrecord --time-limit 3 {video_path}', timeout=10)
    time.sleep(1)
    try:
        with open(video_path, 'rb') as f:
            video_data = base64.b64encode(f.read()).decode('utf-8')
        _run_cmd(f'rm -f {video_path}')
        if video_data:
            logger.info(f"[VIDEO] Recorded ({len(video_data)} bytes b64)")
        else:
            logger.error("[VIDEO] Empty file")
        return video_data
    except Exception as e:
        logger.error(f"[VIDEO] Failed: {e}")
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
# SMART WATCHDOG — uses multiple signals before triggering reconnect
# ---------------------------------------------------------------------------
def evaluate_roblox_health():
    """Returns (healthy: bool, reason: str). Multi-signal evaluation."""
    # Signal 1: Lua disconnect file (highest priority — instant signal from inside Roblox)
    try:
        if os.path.exists(DISCONNECT_SIGNAL_FILE):
            with open(DISCONNECT_SIGNAL_FILE, 'r') as f:
                signal = f.read().strip()
            os.remove(DISCONNECT_SIGNAL_FILE)
            state.last_lua_signal_time = time.time()
            logger.warning(f"[WATCHDOG] Lua disconnect signal: {signal[:80]}")
            return False, "lua_disconnect_signal"
    except Exception:
        pass

    # If we just reconnected, give a long grace period before checking anything else
    if state.last_reconnect_time > 0 and time.time() - state.last_reconnect_time < POST_RECONNECT_COOLDOWN_SEC:
        return True, "cooldown"

    # If currently reconnecting, don't double-fire
    if state.roblox_state == "reconnecting":
        return True, "reconnecting_in_progress"

    # Signal 2: PID exists and is alive
    pid = get_roblox_pid()
    pid_alive = bool(pid) and is_process_alive(pid)
    if pid_alive:
        state.last_pid_seen_time = time.time()

    # Signal 3: Activity manager knows about Roblox
    activity_state = get_roblox_activity_state()
    if activity_state in ("foreground", "background"):
        state.last_activity_alive_time = time.time()

    # If we're in the launch grace window, be lenient
    in_grace = (time.time() - state.last_state_change_time) < LAUNCH_GRACE_SEC

    if pid_alive and activity_state in ("foreground", "background"):
        # Both signals agree — healthy. Run OCR disconnect check.
        if capture_and_check_disconnect():
            state.consecutive_ocr_hits += 1
            logger.warning(f"[WATCHDOG] Disconnect text detected (consecutive: {state.consecutive_ocr_hits})")
            if state.consecutive_ocr_hits >= 2:
                state.stats["kicks"] += 1
                state.consecutive_ocr_hits = 0
                return False, "ocr_disconnect"
        else:
            state.consecutive_ocr_hits = 0
        _set_state("healthy")
        return True, "healthy"

    if in_grace:
        # Within launch grace — don't trigger reconnect yet
        logger.info(f"[WATCHDOG] In launch grace (pid_alive={pid_alive}, activity={activity_state})")
        return True, "in_grace"

    if not pid_alive and activity_state == "stopped":
        # Both signals agree Roblox is gone
        if time.time() - state.last_pid_seen_time > 15:
            logger.warning("[WATCHDOG] Roblox fully stopped (no PID, no activity)")
            return False, "process_gone"

    # Conflicting signals — wait it out
    logger.info(f"[WATCHDOG] Conflicting signals (pid_alive={pid_alive}, activity={activity_state}) — waiting")
    return True, "conflicting_signals"


def watchdog_loop():
    logger.info("[STARTUP] Watchdog started (smart multi-signal)")
    while True:
        time.sleep(state.watchdog_interval_minutes * 60)
        if not state.watchdog_enabled:
            continue
        try:
            healthy, reason = evaluate_roblox_health()
            if not healthy:
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
        if state.roblox_state == "reconnecting":
            continue
        if state.last_reconnect_time > 0 and time.time() - state.last_reconnect_time < POST_RECONNECT_COOLDOWN_SEC:
            continue
        try:
            # Only react to Lua signal + OCR here — leave PID checks to the main watchdog
            if os.path.exists(DISCONNECT_SIGNAL_FILE):
                with open(DISCONNECT_SIGNAL_FILE, 'r') as f:
                    signal = f.read().strip()
                os.remove(DISCONNECT_SIGNAL_FILE)
                state.last_lua_signal_time = time.time()
                logger.warning(f"[FAST] Lua disconnect: {signal[:80]}")
                reconnect_game(reason="lua_disconnect_signal")
                continue

            # If Roblox is in foreground, run OCR check
            pid = get_roblox_pid()
            if not pid:
                continue
            if not is_process_alive(pid):
                continue
            if capture_and_check_disconnect():
                state.consecutive_ocr_hits += 1
                if state.consecutive_ocr_hits >= 2:
                    logger.warning("[FAST] 2 consecutive OCR hits — reconnecting")
                    state.stats["kicks"] += 1
                    reconnect_game(reason="ocr_disconnect_fast")
                    state.consecutive_ocr_hits = 0
            else:
                state.consecutive_ocr_hits = 0
        except Exception as e:
            logger.error(f"[FAST] Error: {e}")


# ---------------------------------------------------------------------------
# STATUS CACHE
# ---------------------------------------------------------------------------
_cache = {"data": None, "ts": 0}


def get_status_dict():
    now = time.time()
    if _cache["data"] and (now - _cache["ts"]) < 3:
        return _cache["data"]
    sys_info = get_system_info()
    state.brightness = get_brightness()
    data = {
        "roblox_state": state.roblox_state,
        "roblox_running": bool(get_roblox_pid()),
        "battery": get_battery(),
        "cpu_temp": sys_info.get("cpu_temp"),
        "ram_total": sys_info.get("ram_total"),
        "ram_free": sys_info.get("ram_free"),
        "uptime": sys_info.get("uptime"),
        "internet": has_internet(),
        "crashes_today": state.stats["crashes"],
        "kicks_today": state.stats["kicks"],
        "network_drops": state.stats["network_drops"],
        "watchdog_enabled": state.watchdog_enabled,
        "is_paused": state.is_paused,
        "interval": state.watchdog_interval_minutes,
        "game_link": state.current_game_link,
        "brightness": state.brightness,
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

    def do_OPTIONS(self):
        self._send_json({"status": "ok"})

    def do_GET(self):
        path = self.path.split('?')[0]
        if path == '/api/status':
            self._send_json(get_status_dict())
        elif path == '/api/crashes':
            self._send_json({"crashes": state.crash_log[:20]})
        elif path == '/api/screenshot':
            img_path = "/sdcard/rbx_manual.png"
            _run_cmd(f'screencap -p {img_path}')
            try:
                with open(img_path, 'rb') as f:
                    img_data = base64.b64encode(f.read()).decode('utf-8')
                _run_cmd(f'rm -f {img_path}')
                self._send_json({"image": img_data, "error": None})
            except Exception as e:
                self._send_json({"image": "", "error": str(e)})
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
        body = self._read_body()

        if path == '/api/restart':
            threading.Thread(target=reconnect_game, args=("manual_restart",), daemon=True).start()
            self._send_json({"status": "initiated", "estimated_seconds": 15})
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
    logger.info("[STARTUP] Reconnector API v7 starting...")
    threading.Thread(target=watchdog_loop, daemon=True).start()
    threading.Thread(target=fast_disconnect_checker, daemon=True).start()
    server = ThreadedHTTPServer((HOST, PORT), RequestHandler)
    logger.info(f"[STARTUP] Server running on http://{HOST}:{PORT}")
    logger.info("[STARTUP] All systems online.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("[SHUTDOWN] Stopped")
        server.shutdown()


if __name__ == "__main__":
    main()
