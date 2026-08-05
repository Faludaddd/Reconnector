"""
Reconnector API Server v4
=========================
Lightweight HTTP server using Python standard library only.
"""
import os
import time
import subprocess
import json
import re
import logging
import sys
import base64
import threading
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
POST_RECONNECT_COOLDOWN_SEC = 120
ANTI_LOOP_THRESHOLD = 4
ANTI_LOOP_WINDOW_SEC = 600

DISCONNECT_KEYWORDS = [
    "disconnected", "reconnect unsuccessful", "lost connection",
    "failed to connect", "connection lost", "you have been kicked",
    "please rejoin", "has been removed", "experience failed to load",
    "the connection to the server was lost", "your connection has timed out",
]

# LOGGING
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

# STATE
class State:
    current_game_link = "https://www.roblox.com/games/84515722934860/Anime-Expeditions"
    is_paused = False
    watchdog_enabled = True
    watchdog_interval_minutes = 1
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

# SHELL HELPERS
def _run_cmd(cmd, timeout=DEFAULT_TIMEOUT):
    try:
        result = subprocess.run(['rish', '-c', cmd], capture_output=True, text=True, timeout=timeout)
        return result.stdout.strip()
    except: return ""

def get_battery():
    try:
        result = subprocess.run(['rish', '-c', 'dumpsys battery | grep level'], capture_output=True, text=True, timeout=5)
        for line in result.stdout.splitlines():
            if line.strip().startswith("level:"):
                try: return int(line.split(":")[1].strip())
                except: return -1
        return -1
    except: return -1

def get_roblox_pid():
    try:
        result = subprocess.run(['rish', '-c', f'pidof {PACKAGE}'], capture_output=True, text=True, timeout=8)
        return result.stdout.strip()
    except: return ""

def is_process_alive(pid_str):
    if not pid_str: return False
    try:
        for pid in pid_str.split():
            result = subprocess.run(['rish', '-c', f'cat /proc/{pid}/status 2>/dev/null | grep "^State:"'], capture_output=True, text=True, timeout=3)
            status = result.stdout.strip()
            if status and "zombie" not in status.lower() and "dead" not in status.lower():
                return True
        return False
    except: return False

def has_internet():
    try:
        result = subprocess.run(['rish', '-c', 'ping -c 1 -W 3 8.8.8.8'], capture_output=True, text=True, timeout=6)
        return result.returncode == 0
    except: return False

def get_system_info():
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

def capture_and_check_disconnect():
    img_path = "/sdcard/rbx_watchdog.png"
    text = _run_cmd(f'screencap -p {img_path} && magick {img_path} -gravity Center -crop 40x40%+0+0 -resize 480x -colorspace Gray -threshold 50% png:- | tesseract stdin stdout --psm 3; rm -f {img_path}', timeout=20)
    if any(w in text.lower() for w in DISCONNECT_KEYWORDS): return True
    text2 = _run_cmd(f'screencap -p {img_path} && magick {img_path} -gravity Center -crop 40x40%+0+0 -resize 480x -colorspace Gray -threshold 50% png:- | tesseract stdin stdout --psm 6; rm -f {img_path}', timeout=20)
    return any(w in text2.lower() for w in DISCONNECT_KEYWORDS)

# OPTIMIZATION COMMANDS
def apply_optimization(name, enabled):
    if name == "kill_bg" and enabled:
        apps = ["com.android.chrome", "com.google.android.youtube", "com.spotify.music", "com.netflix.mediaclient", "com.facebook.katana", "com.instagram.android", "com.snapchat.android", "com.twitter.android", "com.discord", "com.whatsapp"]
        for app in apps:
            _run_cmd(f'am force-stop {app}', timeout=3)
        logger.info("[OPT] Killed background apps")
    elif name == "process_limit" and enabled:
        _run_cmd('settings put global background_process_limit 0', timeout=3)
        logger.info("[OPT] Process limit set to 0")
    elif name == "process_limit" and not enabled:
        _run_cmd('settings put global background_process_limit -1', timeout=3)
        logger.info("[OPT] Process limit restored")
    elif name == "no_animations" and enabled:
        _run_cmd('settings put global window_animation_scale 0', timeout=3)
        _run_cmd('settings put global transition_animation_scale 0', timeout=3)
        _run_cmd('settings put global animator_duration_scale 0', timeout=3)
        logger.info("[OPT] Animations disabled")
    elif name == "no_animations" and not enabled:
        _run_cmd('settings put global window_animation_scale 1', timeout=3)
        _run_cmd('settings put global transition_animation_scale 1', timeout=3)
        _run_cmd('settings put global animator_duration_scale 1', timeout=3)
        logger.info("[OPT] Animations restored")
    elif name == "force_gpu" and enabled:
        _run_cmd('settings put system debug.hwui.render 1', timeout=3)
        logger.info("[OPT] Force GPU enabled")
    elif name == "force_gpu" and not enabled:
        _run_cmd('settings put system debug.hwui.render false', timeout=3)
        logger.info("[OPT] Force GPU disabled")
    elif name == "no_bluetooth" and enabled:
        _run_cmd('svc bluetooth disable', timeout=5)
        logger.info("[OPT] Bluetooth disabled")
    elif name == "no_bluetooth" and not enabled:
        _run_cmd('svc bluetooth enable', timeout=5)
        logger.info("[OPT] Bluetooth enabled")

# ROBLOX LAUNCH LOGIC
def launch_roblox(launch_url, force_kill=True):
    if force_kill:
        logger.info("[LAUNCH] Force-stopping Roblox...")
        _run_cmd(f'am force-stop {PACKAGE}')
        time.sleep(1.5)
        pid = get_roblox_pid()
        if pid:
            logger.warning(f"[LAUNCH] Killing PID {pid.split()[0]}...")
            _run_cmd(f'kill -9 {pid.split()[0]}')
            time.sleep(1)
    else:
        pid = get_roblox_pid()
        if pid and is_process_alive(pid):
            logger.info(f"[LAUNCH] Roblox already running (PID {pid.split()[0]})")
            _run_cmd(f'am start -a android.intent.action.VIEW -d "{launch_url}"')
            return True
    
    logger.info(f"[LAUNCH] Launching: {launch_url}")
    _run_cmd(f'am start -a android.intent.action.VIEW -d "{launch_url}"', timeout=10)
    
    logger.info("[LAUNCH] Waiting for process...")
    deadline = time.time() + 25
    time.sleep(3)
    while time.time() < deadline:
        pid = get_roblox_pid()
        if pid and is_process_alive(pid):
            logger.info(f"[LAUNCH] Roblox started (PID {pid.split()[0]})")
            return True
        time.sleep(1.5)
    
    logger.warning("[LAUNCH] Primary failed, trying component launch...")
    _run_cmd(f'am start -n {PACKAGE}/.startup.ActivitySplash')
    time.sleep(5)
    pid = get_roblox_pid()
    if pid and is_process_alive(pid):
        logger.info(f"[LAUNCH] Started via component (PID {pid.split()[0]})")
        return True
    logger.error("[LAUNCH] All launch methods failed")
    return False

def reconnect_game(reason="unknown", clear_cache=False):
    with reconnect_lock:
        recent = [t for t in state.reconnect_timestamps if time.time() - t < 60]
        if recent:
            logger.info("[SKIP] Reconnect in progress")
            return
        
        state.stats["crashes"] += 1
        state.reconnect_timestamps.append(time.time())
        state.last_crash_reason = reason
        state.roblox_state = "reconnecting"
        state.crash_log.insert(0, {"timestamp": int(time.time()), "reason": reason})
        if len(state.crash_log) > 50: state.crash_log = state.crash_log[:50]
        
        logger.info(f"[RECONNECTOR] Trigger: {reason}")
        m = re.search(r'/games/(\d+)', state.current_game_link)
        launch_url = f"roblox://placeId={m.group(1)}" if m else state.current_game_link
        
        max_attempts = 3
        backoff = [0, 8, 15]
        relaunched = False
        
        for attempt in range(max_attempts):
            if attempt > 0:
                logger.info(f"[RECONNECTOR] Attempt {attempt+1} after {backoff[attempt]}s...")
                time.sleep(backoff[attempt])
            else:
                logger.info(f"[RECONNECTOR] Attempt 1/{max_attempts}...")
            
            relaunched = launch_roblox(launch_url, force_kill=True)
            if relaunched:
                logger.info(f"[RECONNECTOR] Success on attempt {attempt+1}!")
                break
            elif attempt == max_attempts - 1:
                logger.info("[RECONNECTOR] Final attempt without kill...")
                relaunched = launch_roblox(launch_url, force_kill=False)
                if relaunched:
                    logger.info("[RECONNECTOR] Success on final attempt!")
                    break
        
        state.consecutive_ocr_hits = 0
        state.last_reconnect_time = time.time()
        state.roblox_state = "loading" if relaunched else "offline"
        if not relaunched:
            logger.error("[RECONNECTOR] ALL ATTEMPTS FAILED")

# WATCHDOG (Main monitoring loop)
def watchdog_loop():
    logger.info("[STARTUP] Watchdog started")
    while True:
        time.sleep(state.watchdog_interval_minutes * 60)
        if not state.watchdog_enabled:
            continue
        if state.last_reconnect_time > 0 and time.time() - state.last_reconnect_time < POST_RECONNECT_COOLDOWN_SEC:
            continue
        if state.roblox_state == "reconnecting":
            continue
        
        # Check disconnect signal file
        try:
            if os.path.exists(DISCONNECT_SIGNAL_FILE):
                with open(DISCONNECT_SIGNAL_FILE, 'r') as f: signal = f.read().strip()
                os.remove(DISCONNECT_SIGNAL_FILE)
                logger.warning(f"[WATCHDOG] Lua disconnect: {signal[:80]}")
                reconnect_game(reason="lua_disconnect_signal")
                continue
        except: pass
        
        # Check PID
        pid = get_roblox_pid()
        if not pid:
            logger.warning("[WATCHDOG] Roblox PID not found")
            # Confirm gone
            time.sleep(5)
            pid2 = get_roblox_pid()
            if not pid2:
                logger.warning("[WATCHDOG] Roblox confirmed gone - reconnecting")
                reconnect_game(reason="process_gone")
            else:
                logger.info("[WATCHDOG] Roblox came back - false alarm")
            continue
        
        if not is_process_alive(pid):
            logger.warning(f"[WATCHDOG] PID {pid.split()[0]} zombie/dead")
            time.sleep(5)
            if not is_process_alive(pid):
                reconnect_game(reason="process_dead")
            continue
        
        logger.info(f"[WATCHDOG] Roblox running (PID {pid.split()[0]}) - state: healthy")
        state.roblox_state = "healthy"
        
        # OCR disconnect check
        if capture_and_check_disconnect():
            state.consecutive_ocr_hits += 1
            logger.warning(f"[WATCHDOG] Disconnect text detected (consecutive: {state.consecutive_ocr_hits})")
            if state.consecutive_ocr_hits >= 2:
                logger.warning("[WATCHDOG] 2 consecutive - reconnecting")
                state.stats["kicks"] += 1
                reconnect_game(reason="ocr_disconnect")
                state.consecutive_ocr_hits = 0
        else:
            state.consecutive_ocr_hits = 0

# FAST DISCONNECT CHECKER (5s)
def fast_disconnect_checker():
    logger.info("[STARTUP] Fast checker active (5s)")
    while True:
        time.sleep(5)
        if not state.watchdog_enabled: continue
        if state.last_reconnect_time > 0 and time.time() - state.last_reconnect_time < POST_RECONNECT_COOLDOWN_SEC: continue
        if state.roblox_state == "reconnecting": continue
        
        try:
            if os.path.exists(DISCONNECT_SIGNAL_FILE):
                with open(DISCONNECT_SIGNAL_FILE, 'r') as f: signal = f.read().strip()
                os.remove(DISCONNECT_SIGNAL_FILE)
                logger.warning(f"[FAST] Lua disconnect: {signal[:80]}")
                reconnect_game(reason="lua_disconnect_signal")
                continue
        except: pass
        
        pid = get_roblox_pid()
        if not pid: continue
        
        if capture_and_check_disconnect():
            state.consecutive_ocr_hits += 1
            if state.consecutive_ocr_hits >= 2:
                logger.warning("[FAST] 2 consecutive - reconnecting")
                state.stats["kicks"] += 1
                reconnect_game(reason="ocr_disconnect_fast")
                state.consecutive_ocr_hits = 0
        else:
            state.consecutive_ocr_hits = 0

# STATUS CACHE
_status_cache = {"data": None, "ts": 0}
def get_status_dict():
    now = time.time()
    if _status_cache["data"] and (now - _status_cache["ts"]) < 3:
        return _status_cache["data"]
    
    data = {
        "roblox_state": state.roblox_state,
        "roblox_running": bool(get_roblox_pid()),
        "battery": get_battery(),
        "cpu_temp": get_system_info().get("cpu_temp"),
        "ram_total": get_system_info().get("ram_total"),
        "ram_free": get_system_info().get("ram_free"),
        "uptime": get_system_info().get("uptime"),
        "internet": has_internet(),
        "crashes_today": state.stats["crashes"],
        "kicks_today": state.stats["kicks"],
        "network_drops": state.stats["network_drops"],
        "watchdog_enabled": state.watchdog_enabled,
        "is_paused": state.is_paused,
        "interval": state.watchdog_interval_minutes,
        "game_link": state.current_game_link,
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
    _status_cache["data"] = data
    _status_cache["ts"] = now
    return data

# HTTP SERVER
class RequestHandler(BaseHTTPRequestHandler):
    def _send_json(self, data, code=200):
        try:
            self.send_response(code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
            self.send_header('Access-Control-Allow-Headers', 'Content-Type')
            self.end_headers()
            self.wfile.write(json.dumps(data).encode('utf-8'))
        except: pass

    def _read_body(self):
        length = int(self.headers.get('Content-Length', 0))
        if length > 0:
            return json.loads(self.rfile.read(length).decode('utf-8'))
        return {}

    def do_OPTIONS(self):
        self._send_json({"status": "ok"})

    def do_GET(self):
        path = self.path.split('?')[0]
        if path == '/api/status': self._send_json(get_status_dict())
        elif path == '/api/crashes': self._send_json({"crashes": state.crash_log[:20]})
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
        elif path == '/api/logs':
            try:
                with open(LOG_FILE, 'r') as f: lines = f.readlines()[-100:]
                self._send_json({"logs": lines})
            except: self._send_json({"logs": []})
        else: self._send_json({"error": "Not found"}, 404)

    def do_POST(self):
        path = self.path.split('?')[0]
        body = self._read_body()
        
        if path == '/api/restart':
            threading.Thread(target=reconnect_game, args=("manual_restart", True), daemon=True).start()
            self._send_json({"status": "initiated"})
        elif path == '/api/watchdog/toggle':
            state.watchdog_enabled = not state.watchdog_enabled
            self._send_json({"status": "ok", "enabled": state.watchdog_enabled})
        elif path == '/api/clear-anti-loop':
            state.reconnect_timestamps = []
            state.is_paused = False
            self._send_json({"status": "ok"})
        elif path.startswith('/api/interval/'):
            state.watchdog_interval_minutes = int(path.split('/')[-1])
            self._send_json({"status": "ok"})
        elif path == '/api/game-link':
            state.current_game_link = body.get('url', '')
            self._send_json({"status": "ok"})
        elif path.startswith('/api/optimize/'):
            name = path.split('/')[-1]
            enabled = body.get('enabled', False)
            if name in ["kill_bg", "process_limit", "no_animations", "force_gpu", "no_bluetooth"]:
                setattr(state, f"opt_{name}", enabled)
                # Apply immediately
                threading.Thread(target=apply_optimization, args=(name, enabled), daemon=True).start()
                self._send_json({"status": "ok", "applied": True})
            else:
                self._send_json({"error": "Unknown optimization"}, 404)
        else: self._send_json({"error": "Not found"}, 404)

    def log_message(self, format, *args): pass

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer): pass

# STARTUP
def main():
    logger.info("[STARTUP] Reconnector API v4 starting...")
    logger.info("[STARTUP] Starting watchdog...")
    threading.Thread(target=watchdog_loop, daemon=True).start()
    logger.info("[STARTUP] Starting fast disconnect checker...")
    threading.Thread(target=fast_disconnect_checker, daemon=True).start()
    
    server = ThreadedHTTPServer((HOST, PORT), RequestHandler)
    logger.info(f"[STARTUP] Server running on http://{HOST}:{PORT}")
    logger.info("[STARTUP] All systems online. Waiting for connections...")
    
    try: server.serve_forever()
    except KeyboardInterrupt:
        logger.info("[SHUTDOWN] Server stopped")
        server.shutdown()

if __name__ == "__main__":
    main()
