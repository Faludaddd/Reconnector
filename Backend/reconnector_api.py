"""
Reconnector API Server
======================
FastAPI backend that replaces discord.py. Runs on Termux.
Exposes HTTP endpoints and a WebSocket for the iOS app to control the bot.
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
import uuid
import io
from datetime import datetime, timedelta, timezone
from logging.handlers import RotatingFileHandler
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException, Security, Depends
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel
import uvicorn

# ============================================================
# CONFIG
# ============================================================
PACKAGE = "com.roblox.client"
BASE_DIR = "/data/data/com.termux/files/home"
LOG_FILE = f"{BASE_DIR}/reconnector.log"
CRASH_LOG_FILE = f"{BASE_DIR}/reconnector_crash_log.json"
STATE_FILE = f"{BASE_DIR}/reconnector_state.json"
DISCONNECT_SIGNAL_FILE = "/sdcard/AE_disconnect_signal.txt"

AUTH_TOKEN = os.environ.get("AUTH_TOKEN", "changeme")
HOST = "0.0.0.0"
PORT = 8080

DEFAULT_TIMEOUT = 15
SCREENSHOT_COOLDOWN_SEC = 15
POST_RECONNECT_COOLDOWN_SEC = 120
ANTI_LOOP_THRESHOLD = 4
ANTI_LOOP_WINDOW_SEC = 600
AUTO_RESUME_AFTER_SEC = 1800

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
    was_network_down = False
    watchdog_enabled = True
    watchdog_interval_minutes = 1
    brightness_level = 100
    last_watchdog_cycle = None
    last_crash_reason = "-"
    last_crash_at = None
    paused_at = None
    session_start = time.time()
    bot_first_start_time = time.time()
    last_screenshot_at = 0
    watchdog_cycles_completed = 0
    consecutive_ocr_hits = 0
    roblox_state = "unknown"
    last_reconnect_time = 0
    stats = {"raids": 0, "crashes": 0, "kicks": 0, "network_drops": 0}
    yesterday_stats = {"crashes": 0, "kicks": 0, "network_drops": 0}
    last_reset_date = datetime.now().date()
    reconnect_timestamps = []
    crash_log = []
    opt_kill_bg_apps = False
    opt_process_limit = False
    opt_disable_animations = False
    opt_force_gpu = False
    opt_disable_bluetooth = False

state = State()

# ============================================================
# SHELL / RISH HELPERS
# ============================================================
def _run_cmd_sync(cmd, timeout):
    try:
        result = subprocess.run(['rish', '-c', cmd], capture_output=True, text=True, timeout=timeout)
        return result.stdout.strip()
    except Exception:
        return ""

async def run_cmd(cmd, timeout=DEFAULT_TIMEOUT):
    return await asyncio.to_thread(_run_cmd_sync, cmd, timeout)

def _ping_sync(host):
    try:
        result = subprocess.run(['rish', '-c', f'ping -c 1 -W 3 {host}'], capture_output=True, timeout=6)
        return result.returncode == 0
    except Exception:
        return False

async def has_internet():
    if await asyncio.to_thread(_ping_sync, "8.8.8.8"): return True
    return await asyncio.to_thread(_ping_sync, "1.1.1.1")

def _battery_sync():
    try:
        result = subprocess.run(['rish', '-c', 'dumpsys battery | grep level'], capture_output=True, text=True, timeout=5)
        for line in result.stdout.splitlines():
            if line.strip().startswith("level:"):
                try: return int(line.split(":")[1].strip())
                except ValueError: return -1
        return -1
    except Exception: return -1

async def get_battery():
    return await asyncio.to_thread(_battery_sync)

def _get_roblox_pid_sync():
    try:
        result = subprocess.run(['rish', '-c', f'pidof {PACKAGE}'], capture_output=True, text=True, timeout=8)
        return result.stdout.strip()
    except Exception: return ""

async def get_roblox_pid():
    return await asyncio.to_thread(_get_roblox_pid_sync)

def _is_process_alive_sync(pid_str):
    if not pid_str: return False
    try:
        for pid in pid_str.split():
            result = subprocess.run(['rish', '-c', f'cat /proc/{pid}/status 2>/dev/null | grep "^State:"'], capture_output=True, text=True, timeout=3)
            status_line = result.stdout.strip()
            if status_line and "zombie" not in status_line.lower() and "dead" not in status_line.lower():
                return True
        return False
    except Exception: return False

async def is_process_alive(pid_str):
    return await asyncio.to_thread(_is_process_alive_sync, pid_str)

async def is_roblox_actually_running():
    pid = await get_roblox_pid()
    if not pid: return False
    alive = await is_process_alive(pid)
    if alive: return True
    return False

async def confirm_roblox_gone(rechecks=2, delay=5):
    for i in range(rechecks):
        pid = await get_roblox_pid()
        if pid:
            alive = await is_process_alive(pid)
            if alive: return False
        if i < rechecks - 1: await asyncio.sleep(delay)
    return True

async def capture_and_check_disconnect():
    img_path = "/sdcard/rbx_watchdog.png"
    text = await run_cmd(
        f'screencap -p {img_path} && '
        f'magick {img_path} -gravity Center -crop 40x40%+0+0 -resize 480x '
        f'-colorspace Gray -threshold 50% png:- | tesseract stdin stdout --psm 3; '
        f'rm -f {img_path}',
        timeout=20,
    )
    text = text.lower()
    found = any(w in text for w in DISCONNECT_KEYWORDS)
    if found: return True
    text2 = await run_cmd(
        f'screencap -p {img_path} && '
        f'magick {img_path} -gravity Center -crop 40x40%+0+0 -resize 480x '
        f'-colorspace Gray -threshold 50% png:- | tesseract stdin stdout --psm 6; '
        f'rm -f {img_path}',
        timeout=20,
    )
    return any(w in text2.lower() for w in DISCONNECT_KEYWORDS)

def _get_system_info_sync():
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

async def get_system_info():
    return await asyncio.to_thread(_get_system_info_sync)

# ============================================================
# RECONNECT LOGIC
# ============================================================
async def reconnect_game(reason="unknown", clear_cache=False):
    async state_lock:
        recent = [t for t in state.reconnect_timestamps if time.time() - t < 60]
        if recent:
            print(f"[SKIP] Reconnect already in progress")
            return

        state.stats["crashes"] += 1
        state.reconnect_timestamps.append(time.time())
        state.last_crash_reason = reason
        state.last_crash_at = datetime.now()
        state.crash_log.insert(0, {"timestamp": int(time.time()), "reason": reason})
        if len(state.crash_log) > 200: state.crash_log = state.crash_log[:200]

        print(f"[RECONNECTOR] Trigger received: {reason}")
        logger.info(f"Reconnector triggered: {reason}")

        m = re.search(r'/games/(\d+)', state.current_game_link)
        launch_url = f"roblox://placeId={m.group(1)}" if m else state.current_game_link

        max_attempts = 3
        backoff_delays = [0, 10, 20]
        relaunched = False

        for attempt in range(max_attempts):
            if attempt > 0:
                delay = backoff_delays[attempt]
                print(f"[RECONNECTOR] Attempt {attempt + 1}/{max_attempts} after {delay}s backoff...")
                await asyncio.sleep(delay)
            else:
                print(f"[RECONNECTOR] Attempt 1/{max_attempts}...")

            print("[RECONNECTOR] Step 1: Force-stopping Roblox...")
            await run_cmd(f'am force-stop {PACKAGE}')
            await asyncio.sleep(1)

            pid_check = await get_roblox_pid()
            if pid_check:
                print(f"[RECONNECTOR] Step 2: Killing PID {pid_check.split()[0]}...")
                await run_cmd(f'kill -9 {pid_check.split()[0]}')
                await asyncio.sleep(0.5)
            else:
                print("[RECONNECTOR] Step 2: Roblox stopped cleanly")

            print(f"[RECONNECTOR] Step 3: Launching Roblox ({launch_url})...")
            await run_cmd(f'am start -a android.intent.action.VIEW -d "{launch_url}"')

            print("[RECONNECTOR] Step 4: Waiting for Roblox to start...")
            poll_deadline = time.time() + 30
            await asyncio.sleep(3)
            while time.time() < poll_deadline:
                pid = await get_roblox_pid()
                if pid and await is_process_alive(pid):
                    relaunched = True
                    break
                await asyncio.sleep(1.5)

            if relaunched:
                print(f"[RECONNECTOR] Recovery successful on attempt {attempt + 1}!")
                break
            else:
                print(f"[RECONNECTOR] Attempt {attempt + 1} failed")

        state.consecutive_ocr_hits = 0
        state.last_reconnect_time = time.time()
        state.roblox_state = "loading"

# ============================================================
# FAST DISCONNECT CHECKER (5s interval)
# ============================================================
async def fast_disconnect_checker():
    while True:
        await asyncio.sleep(5)
        if not state.watchdog_enabled: continue
        if state.last_reconnect_time > 0 and time.time() - state.last_reconnect_time < POST_RECONNECT_COOLDOWN_SEC: continue
        if state.roblox_state == "reconnecting": continue

        try:
            if os.path.exists(DISCONNECT_SIGNAL_FILE):
                with open(DISCONNECT_SIGNAL_FILE, 'r') as f: signal = f.read().strip()
                os.remove(DISCONNECT_SIGNAL_FILE)
                print(f"[FAST] Disconnect signal from Lua: {signal[:80]}")
                state.roblox_state = "reconnecting"
                await reconnect_game(reason="lua_disconnect_signal")
                continue
        except: pass

        pid = await get_roblox_pid()
        if not pid: continue

        if await capture_and_check_disconnect():
            state.consecutive_ocr_hits += 1
            if state.consecutive_ocr_hits >= 2:
                print("[FAST] 2 consecutive disconnect detections — reconnecting")
                state.roblox_state = "reconnecting"
                state.stats["kicks"] += 1
                await reconnect_game(reason="ocr_disconnect_fast")
                state.consecutive_ocr_hits = 0
        else:
            state.consecutive_ocr_hits = 0

# ============================================================
# FASTAPI APP
# ============================================================
app = FastAPI(title="Reconnector API")
security = HTTPBearer()

def verify_token(credentials: HTTPAuthorizationCredentials = Security(security)):
    if credentials.credentials != AUTH_TOKEN:
        raise HTTPException(status_code=401, detail="Invalid token")
    return True

class WebSocketManager:
    def __init__(self):
        self.active_connections = []
    async def connect(self, ws: WebSocket):
        await ws.accept()
        self.active_connections.append(ws)
    def disconnect(self, ws: WebSocket):
        self.active_connections.remove(ws)
    async def broadcast(self, msg: dict):
        for c in self.active_connections:
            try: await c.send_json(msg)
            except: pass

ws_manager = WebSocketManager()

@app.get("/api/status")
async def get_status(auth: bool = Depends(verify_token)):
    battery, sys_info, pid = await asyncio.gather(get_battery(), get_system_info(), get_roblox_pid())
    return {
        "roblox_state": state.roblox_state,
        "roblox_running": bool(pid),
        "battery": battery,
        "cpu_temp": sys_info.get("cpu_temp"),
        "ram_total": sys_info.get("ram_total"),
        "ram_free": sys_info.get("ram_free"),
        "uptime": sys_info.get("uptime"),
        "crashes_today": state.stats["crashes"],
        "kicks_today": state.stats["kicks"],
        "watchdog_enabled": state.watchdog_enabled,
        "is_paused": state.is_paused,
        "interval": state.watchdog_interval_minutes,
        "game_link": state.current_game_link,
        "brightness": state.brightness_level,
        "optimizations": {
            "kill_bg": state.opt_kill_bg_apps,
            "process_limit": state.opt_process_limit,
            "no_animations": state.opt_disable_animations,
            "force_gpu": state.opt_force_gpu,
            "no_bluetooth": state.opt_disable_bluetooth,
        }
    }

@app.post("/api/restart")
async def restart_roblox(auth: bool = Depends(verify_token)):
    state.roblox_state = "reconnecting"
    asyncio.create_task(reconnect_game(reason="manual_restart", clear_cache=True))
    return {"status": "initiated"}

@app.get("/api/screenshot")
async def screenshot(auth: bool = Depends(verify_token)):
    img_path = "/sdcard/rbx_manual.png"
    await run_cmd(f'screencap -p {img_path}')
    # Read and return as base64 or file response
    # For simplicity, returning a placeholder. In production, read file and return StreamingResponse
    return {"status": "ok", "path": img_path}

@app.post("/api/black-screen")
async def black_screen(auth: bool = Depends(verify_token)):
    html = "<html><body bgcolor='black'></body></html>"
    with open("/sdcard/black.html", "w") as f: f.write(html)
    await run_cmd('am start -a android.intent.action.VIEW -d "file:///sdcard/black.html" -t "text/html"')
    return {"status": "ok"}

@app.post("/api/brightness/{level}")
async def set_brightness(level: int, auth: bool = Depends(verify_token)):
    state.brightness_level = level
    await run_cmd(f'settings put system screen_brightness {level}')
    return {"status": "ok"}

@app.post("/api/watchdog/toggle")
async def toggle_watchdog(auth: bool = Depends(verify_token)):
    state.watchdog_enabled = not state.watchdog_enabled
    return {"status": "ok", "enabled": state.watchdog_enabled}

@app.post("/api/clear-anti-loop")
async def clear_anti_loop(auth: bool = Depends(verify_token)):
    state.reconnect_timestamps = []
    state.is_paused = False
    return {"status": "ok"}

@app.post("/api/optimize/{name}")
async def toggle_optimize(name: str, enabled: bool = True, auth: bool = Depends(verify_token)):
    if name == "kill_bg": state.opt_kill_bg_apps = enabled
    elif name == "process_limit": state.opt_process_limit = enabled
    elif name == "no_animations": state.opt_disable_animations = enabled
    elif name == "force_gpu": state.opt_force_gpu = enabled
    elif name == "no_bluetooth": state.opt_disable_bluetooth = enabled
    return {"status": "ok"}

class GameLinkModel(BaseModel):
    url: str

@app.post("/api/game-link")
async def set_game_link(data: GameLinkModel, auth: bool = Depends(verify_token)):
    state.current_game_link = data.url
    return {"status": "ok"}

@app.post("/api/interval/{minutes}")
async def set_interval(minutes: int, auth: bool = Depends(verify_token)):
    state.watchdog_interval_minutes = minutes
    return {"status": "ok"}

@app.get("/api/logs")
async def get_logs(auth: bool = Depends(verify_token)):
    try:
        with open(LOG_FILE, 'r') as f:
            lines = f.readlines()[-100:]
        return {"logs": lines}
    except:
        return {"logs": []}

@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await ws_manager.connect(ws)
    try:
        while True:
            await asyncio.sleep(1)
    except WebSocketDisconnect:
        ws_manager.disconnect(ws)

# ============================================================
# STARTUP
# ============================================================
@app.on_event("startup")
async def startup_event():
    print("[STARTUP] Reconnector API starting...")
    print(f"[STARTUP] Auth token: {AUTH_TOKEN[:4]}...")
    asyncio.create_task(fast_disconnect_checker())

if __name__ == "__main__":
    uvicorn.run(app, host=HOST, port=PORT)
