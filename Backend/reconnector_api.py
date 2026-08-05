"""
Reconnector API Server v3 (Lightweight)
=======================================
Uses Python standard library only (no FastAPI/uvicorn/pydantic needed).
This solves the Python 3.14 pydantic-core compilation issue on Termux.
"""
import os
import time
import asyncio
import subprocess
import json
import re
import logging
import signal
import sys
import io
import base64
from datetime import datetime, timedelta, timezone
from logging.handlers import RotatingFileHandler
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
import threading

# ============================================================
# CONFIG
# ============================================================
PACKAGE = "com.roblox.client"
BASE_DIR = "/data/data/com.termux/files/home"
LOG_FILE = f"{BASE_DIR}/reconnector.log"
CRASH_LOG_FILE = f"{BASE_DIR}/reconnector_crash_log.json"
STATE_FILE = f"{BASE_DIR}/reconnector_state.json"
DISCONNECT_SIGNAL_FILE = "/sdcard/AE_disconnect_signal.txt"

AUTH_TOKEN = os.environ.get("AUTH_TOKEN", "reconnector123")
HOST = "0.0.0.0"
PORT = 8080

DEFAULT_TIMEOUT = 15
POST_RECONNECT_COOLDOWN_SEC = 120
ANTI_LOOP_THRESHOLD = 4
ANTI_LOOP_WINDOW_SEC = 600

DISCONNECT_KEYWORDS = [
    "disconnected", "reconnect unsuccessful", "lost connection",
    "failed to connect", "connection lost", "you have been kicked",
    "please rejoin", "has been removed", "experience failed to load",
    "the connection to the server was lost", "your connection has timed out",
]

# ============================================================
# LOGGING
# ============================================================
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
except Exception as e:
    print(f"File logging unavailable: {e}")

# ============================================================
# STATE
# ============================================================
class State:
    current_game_link = "https://www.roblox.com/games/84515722934860/Anime-Expeditions"
    is_paused = False
    is_dark_mode = False
    watchdog_enabled = True
    watchdog_interval_minutes = 1
    brightness_level = 100
    last_crash_reason = "-"
    last_crash_at = None
    session_start = time.time()
    bot_first_start_time = time.time()
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

state = State()
reconnect_lock = threading.Lock()

# ============================================================
# SHELL / RISH HELPERS
# ============================================================
def _run_cmd_sync(cmd, timeout=DEFAULT_TIMEOUT):
    try:
        result = subprocess.run(['rish', '-c', cmd], capture_output=True, text=True, timeout=timeout)
        return result.stdout.strip()
    except Exception:
        return ""

def run_cmd_sync(cmd, timeout=DEFAULT_TIMEOUT):
    return _run_cmd_sync(cmd, timeout)

def get_battery_sync():
    try:
        result = subprocess.run(['rish', '-c', 'dumpsys battery | grep level'], capture_output=True, text=True, timeout=5)
        for line in result.stdout.splitlines():
            if line.strip().startswith("level:"):
                try: return int(line.split(":")[1].strip())
                except: return -1
        return -1
    except: return -1

def get_roblox_pid_sync():
    try:
        result = subprocess.run(['rish', '-c', f'pidof {PACKAGE}'], capture_output=True, text=True, timeout=8)
        return result.stdout.strip()
    except: return ""

def is_process_alive_sync(pid_str):
    if not pid_str: return False
    try:
        for pid in pid_str.split():
            result = subprocess.run(['rish', '-c', f'cat /proc/{pid}/status 2>/dev/null | grep "^State:"'], capture_output=True, text=True, timeout=3)
            status = result.stdout.strip()
            if status and "zombie" not in status.lower() and "dead" not in status.lower():
                return True
        return False
    except: return False

def confirm_roblox_gone_sync(rechecks=2, delay=5):
    for i in range(rechecks):
        pid = get_roblox_pid_sync()
        if pid and is_process_alive_sync(pid): return False
        if i < rechecks - 1: time.sleep(delay)
    return True

def capture_and_check_disconnect_sync():
    img_path = "/sdcard/rbx_watchdog.png"
    text = _run_cmd_sync(
        f'screencap -p {img_path} && magick {img_path} -gravity Center -crop 40x40%+0+0 -resize 480x -colorspace Gray -threshold 50% png:- | tesseract stdin stdout --psm 3; rm -f {img_path}',
        timeout=20,
    )
    if any(w in text.lower() for w in DISCONNECT_KEYWORDS): return True
    text2 = _run_cmd_sync(
        f'screencap -p {img_path} && magick {img_path} -gravity Center -crop 40x40%+0+0 -resize 480x -colorspace Gray -threshold 50% png:- | tesseract stdin stdout --psm 6; rm -f {img_path}',
        timeout=20,
    )
    return any(w in text2.lower() for w in DISCONNECT_KEYWORDS)

def get_system_info_sync():
    info = {"cpu_temp": None, "ram_total": None, "ram_free": None, "uptime": None}
    try:
        result = subprocess.run(['rish', '-c', 'cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null'], capture_output=True, text=True, timeout=3)
        if result.stdout.strip(): info["cpu_temp"] = int(result.stdout.strip()) / 1000.0
    except: pass
    try:
        result = subprocess.run(['rish', '-c', 'cat /proc/meminfo | head -3'], capture_output=True, text=True, timeout=3)
        for line in result.stdout.splitlines():
            if "MemTotal" in line: info["ram_total"] = int(line.split()[1]) // 1024
            elif "MemFree" in line: info["ram_free"] = int(line.split()[1]) // 1024
    except: pass
    try:
        result = subprocess.run(['rish', '-c', 'cat /proc/uptime'], capture_output=True, text=True, timeout=3)
        if result.stdout.strip(): info["uptime"] = int(float(result.stdout.split()[0]))
    except: pass
    return info

def has_internet_sync():
    try:
        result = subprocess.run(['rish', '-c', 'ping -c 1 -W 3 8.8.8.8'], capture_output=True, text=True, timeout=6)
        return result.returncode == 0
    except: return False

# ============================================================
# ROBLOX LAUNCH LOGIC (Completely Rewritten)
# ============================================================
def launch_roblox_sync(launch_url, force_kill_first=True):
    """Launch Roblox with intelligent handling.
    Returns True if Roblox process is confirmed running after launch."""
    
    # Step 1: Kill existing process if requested
    if force_kill_first:
        logger.info("[LAUNCH] Force-stopping any existing Roblox process...")
        _run_cmd_sync(f'am force-stop {PACKAGE}')
        time.sleep(1.5)
        
        # Check if process is still alive
        pid = get_roblox_pid_sync()
        if pid:
            logger.warning(f"[LAUNCH] Process still alive after force-stop, killing PID {pid.split()[0]}...")
            _run_cmd_sync(f'kill -9 {pid.split()[0]}')
            time.sleep(1)
            
            # Verify it's actually dead
            pid2 = get_roblox_pid_sync()
            if pid2:
                logger.error(f"[LAUNCH] Could not kill Roblox process (PID {pid2})")
                # Try harder
                _run_cmd_sync(f'am force-stop {PACKAGE}')
                time.sleep(2)
        else:
            logger.info("[LAUNCH] Roblox stopped cleanly")
    else:
        # Check if Roblox is already running
        pid = get_roblox_pid_sync()
        if pid and is_process_alive_sync(pid):
            logger.info(f"[LAUNCH] Roblox already running (PID {pid.split()[0]})")
            # Still send the launch intent to bring it to foreground
            _run_cmd_sync(f'am start -a android.intent.action.VIEW -d "{launch_url}"')
            return True
    
    # Step 2: Launch Roblox
    logger.info(f"[LAUNCH] Sending launch intent: {launch_url}")
    result = _run_cmd_sync(f'am start -a android.intent.action.VIEW -d "{launch_url}"', timeout=10)
    
    if "Error" in result or "error" in result.lower():
        logger.error(f"[LAUNCH] Launch command returned error: {result}")
    
    # Step 3: Wait for Roblox process to appear
    logger.info("[LAUNCH] Waiting for Roblox process to start...")
    poll_deadline = time.time() + 25
    time.sleep(3)  # Initial wait for process spawn
    
    while time.time() < poll_deadline:
        pid = get_roblox_pid_sync()
        if pid:
            alive = is_process_alive_sync(pid)
            if alive:
                logger.info(f"[LAUNCH] Roblox started successfully (PID {pid.split()[0]})")
                return True
            else:
                logger.warning(f"[LAUNCH] PID {pid} exists but process is zombie, waiting...")
        time.sleep(1.5)
    
    # Step 4: If first launch method failed, try alternative
    logger.warning("[LAUNCH] Primary launch failed, trying component launch...")
    _run_cmd_sync(f'am start -n {PACKAGE}/.startup.ActivitySplash')
    time.sleep(5)
    
    pid = get_roblox_pid_sync()
    if pid and is_process_alive_sync(pid):
        logger.info(f"[LAUNCH] Roblox started via component launch (PID {pid.split()[0]})")
        return True
    
    logger.error("[LAUNCH] All launch methods failed")
    return False


def reconnect_game_sync(reason="unknown", clear_cache=False):
    with reconnect_lock:
        recent = [t for t in state.reconnect_timestamps if time.time() - t < 60]
        if recent:
            logger.info("[SKIP] Reconnect already in progress")
            return

        state.stats["crashes"] += 1
        state.reconnect_timestamps.append(time.time())
        state.last_crash_reason = reason
        state.last_crash_at = datetime.now()
        state.roblox_state = "reconnecting"
        state.crash_log.insert(0, {"timestamp": int(time.time()), "reason": reason})
        if len(state.crash_log) > 50: state.crash_log = state.crash_log[:50]
        
        logger.info(f"[RECONNECTOR] Trigger received: {reason}")

        m = re.search(r'/games/(\d+)', state.current_game_link)
        launch_url = f"roblox://placeId={m.group(1)}" if m else state.current_game_link

        max_attempts = 3
        backoff_delays = [0, 8, 15]
        relaunched = False

        for attempt in range(max_attempts):
            if attempt > 0:
                delay = backoff_delays[attempt]
                logger.info(f"[RECONNECTOR] Attempt {attempt + 1}/{max_attempts} after {delay}s backoff...")
                time.sleep(delay)
            else:
                logger.info(f"[RECONNECTOR] Attempt 1/{max_attempts}...")

            # Use the new intelligent launch function
            relaunched = launch_roblox_sync(launch_url, force_kill_first=True)

            if relaunched:
                logger.info(f"[RECONNECTOR] Recovery successful on attempt {attempt + 1}!")
                break
            else:
                logger.warning(f"[RECONNECTOR] Attempt {attempt + 1} failed - Roblox did not start")
                # On final attempt, try without killing
                if attempt == max_attempts - 1:
                    logger.info("[RECONNECTOR] Final attempt: trying without force-kill...")
                    relaunched = launch_roblox_sync(launch_url, force_kill_first=False)
                    if relaunched:
                        logger.info("[RECONNECTOR] Recovery successful on final attempt!")
                        break

        state.consecutive_ocr_hits = 0
        state.last_reconnect_time = time.time()
        state.roblox_state = "loading" if relaunched else "offline"
        
        if not relaunched:
            logger.error("[RECONNECTOR] ALL RECOVERY ATTEMPTS FAILED - Roblox would not launch")

# ============================================================
# FAST DISCONNECT CHECKER (Background Thread)
# ============================================================
def fast_disconnect_checker():
    logger.info("[STARTUP] Fast disconnect checker active (5s interval)")
    while True:
        time.sleep(5)
        if not state.watchdog_enabled: continue
        if state.last_reconnect_time > 0 and time.time() - state.last_reconnect_time < POST_RECONNECT_COOLDOWN_SEC: continue
        if state.roblox_state == "reconnecting": continue

        try:
            if os.path.exists(DISCONNECT_SIGNAL_FILE):
                with open(DISCONNECT_SIGNAL_FILE, 'r') as f: signal = f.read().strip()
                os.remove(DISCONNECT_SIGNAL_FILE)
                logger.warning(f"[FAST] Disconnect signal from Lua: {signal[:80]}")
                reconnect_game_sync(reason="lua_disconnect_signal")
                continue
        except: pass

        pid = get_roblox_pid_sync()
        if not pid: continue

        if capture_and_check_disconnect_sync():
            state.consecutive_ocr_hits += 1
            if state.consecutive_ocr_hits >= 2:
                logger.warning("[FAST] 2 consecutive disconnect detections — reconnecting")
                state.stats["kicks"] += 1
                reconnect_game_sync(reason="ocr_disconnect_fast")
                state.consecutive_ocr_hits = 0
        else:
            state.consecutive_ocr_hits = 0

# ============================================================
# HTTP SERVER
# ============================================================
# Status cache - prevents running expensive rish commands on every request
_status_cache = {"data": None, "ts": 0}
_STATUS_CACHE_TTL = 3  # 3 seconds

def get_status_dict():
    # Use cached data if less than 3 seconds old
    now = time.time()
    if _status_cache["data"] and (now - _status_cache["ts"]) < _STATUS_CACHE_TTL:
        return _status_cache["data"]
    
    battery = get_battery_sync()
    sys_info = get_system_info_sync()
    pid = get_roblox_pid_sync()
    # Only check internet if we haven't recently (it's slow)
    online = has_internet_sync()
    elapsed = int(now - state.bot_first_start_time)
    
    data = {
        "roblox_state": state.roblox_state,
        "roblox_running": bool(pid),
        "battery": battery,
        "cpu_temp": sys_info.get("cpu_temp"),
        "ram_total": sys_info.get("ram_total"),
        "ram_free": sys_info.get("ram_free"),
        "uptime": sys_info.get("uptime"),
        "internet": online,
        "crashes_today": state.stats["crashes"],
        "kicks_today": state.stats["kicks"],
        "network_drops": state.stats["network_drops"],
        "watchdog_enabled": state.watchdog_enabled,
        "is_paused": state.is_paused,
        "interval": state.watchdog_interval_minutes,
        "game_link": state.current_game_link,
        "brightness": state.brightness_level,
        "last_crash_reason": state.last_crash_reason,
        "last_reconnect": int(state.last_reconnect_time) if state.last_reconnect_time else 0,
        "bot_uptime": elapsed,
        "optimizations": {
            "kill_bg": state.opt_kill_bg,
            "process_limit": state.opt_process_limit,
            "no_animations": state.opt_no_animations,
            "force_gpu": state.opt_force_gpu,
            "no_bluetooth": state.opt_no_bluetooth,
        }
    }
    
    _status_cache["data"] = data
    _status_cache["ts"] = now
    return data

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
        except (ConnectionResetError, BrokenPipeError):
            pass  # Client disconnected before we could respond - ignore

    def _read_body(self):
        content_length = int(self.headers.get('Content-Length', 0))
        if content_length > 0:
            return json.loads(self.rfile.read(content_length).decode('utf-8'))
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
            _run_cmd_sync(f'screencap -p {img_path}')
            try:
                with open(img_path, 'rb') as f:
                    img_data = base64.b64encode(f.read()).decode('utf-8')
                _run_cmd_sync(f'rm -f {img_path}')
                self._send_json({"image": img_data, "error": None})
            except Exception as e:
                self._send_json({"image": "", "error": str(e)})
        elif path == '/api/logs':
            try:
                with open(LOG_FILE, 'r') as f: lines = f.readlines()[-100:]
                self._send_json({"logs": lines})
            except:
                self._send_json({"logs": []})
        else:
            self._send_json({"error": "Not found"}, 404)

    def do_POST(self):
        path = self.path.split('?')[0]
        body = self._read_body()
        
        if path == '/api/restart':
            threading.Thread(target=reconnect_game_sync, args=("manual_restart", True), daemon=True).start()
            self._send_json({"status": "initiated"})
        elif path == '/api/black-screen':
            html = '<html><body bgcolor="black"><div style="position:fixed;top:20px;right:20px;width:50px;height:50px;background:rgba(255,255,255,0.1);border-radius:50%;display:flex;align-items:center;justify-content:center;color:white;font-size:24px;cursor:pointer;" onclick="history.back()">×</div></body></html>'
            with open("/sdcard/black.html", "w") as f: f.write(html)
            _run_cmd_sync('am start -a android.intent.action.VIEW -d "file:///sdcard/black.html" -t "text/html"')
            self._send_json({"status": "ok"})
        elif path == '/api/watchdog/toggle':
            state.watchdog_enabled = not state.watchdog_enabled
            self._send_json({"status": "ok", "enabled": state.watchdog_enabled})
        elif path == '/api/clear-anti-loop':
            state.reconnect_timestamps = []
            state.is_paused = False
            self._send_json({"status": "ok"})
        elif path.startswith('/api/brightness/'):
            level = int(path.split('/')[-1])
            state.brightness_level = level
            _run_cmd_sync(f'settings put system screen_brightness {level}')
            self._send_json({"status": "ok"})
        elif path.startswith('/api/interval/'):
            minutes = int(path.split('/')[-1])
            state.watchdog_interval_minutes = minutes
            self._send_json({"status": "ok"})
        elif path == '/api/game-link':
            state.current_game_link = body.get('url', '')
            self._send_json({"status": "ok"})
        elif path.startswith('/api/optimize/'):
            name = path.split('/')[-1]
            enabled = body.get('enabled', False)
            if name == "kill_bg": state.opt_kill_bg = enabled
            elif name == "process_limit": state.opt_process_limit = enabled
            elif name == "no_animations": state.opt_no_animations = enabled
            elif name == "force_gpu": state.opt_force_gpu = enabled
            elif name == "no_bluetooth": state.opt_no_bluetooth = enabled
            self._send_json({"status": "ok"})
        else:
            self._send_json({"error": "Not found"}, 404)

    def log_message(self, format, *args):
        pass  # Suppress default HTTP logging

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    pass

# ============================================================
# STARTUP
# ============================================================
def main():
    logger.info("[STARTUP] Reconnector API v3 starting (Lightweight HTTP Server)...")
    logger.info(f"[STARTUP] Auth token: {AUTH_TOKEN[:4]}...")
    
    # Start disconnect checker in background
    checker_thread = threading.Thread(target=fast_disconnect_checker, daemon=True)
    checker_thread.start()
    
    # Start HTTP server
    server = ThreadedHTTPServer((HOST, PORT), RequestHandler)
    logger.info(f"[STARTUP] Server running on http://{HOST}:{PORT}")
    
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("[SHUTDOWN] Server stopped")
        server.shutdown()

if __name__ == "__main__":
    main()
