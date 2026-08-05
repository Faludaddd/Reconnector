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
import io
import threading
from datetime import datetime, timedelta, timezone
from logging.handlers import RotatingFileHandler
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException, Security, Depends, Request
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from fastapi.responses import JSONResponse
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

class WebSocketLogHandler(logging.Handler):
    def __init__(self, manager):
        super().__init__()
        self.manager = manager
    def emit(self, record):
        msg = self.format(record)
        self.manager.broadcast_sync({"type": "log", "data": msg, "timestamp": time.time()})

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
    watchdog_enabled = True
    watchdog_interval_minutes = 1
    brightness_level = 100
    last_crash_reason = "-"
    last_crash_at = None
    session_start = time.time()
    roblox_state = "unknown"
    last_reconnect_time = 0
    consecutive_ocr_hits = 0
    stats = {"crashes": 0, "kicks": 0}
    reconnect_timestamps = []
    opt_kill_bg = False
    opt_process_limit = False
    opt_no_animations = False
    opt_force_gpu = False
    opt_no_bluetooth = False

state = State()
state_lock = asyncio.Lock()
reconnect_lock = asyncio.Lock()

# ============================================================
# SHELL / RISH HELPERS
# ============================================================
def _run_cmd_sync(cmd, timeout=DEFAULT_TIMEOUT):
    try:
        result = subprocess.run(['rish', '-c', cmd], capture_output=True, text=True, timeout=timeout)
        return result.stdout.strip()
    except Exception:
        return ""

async def run_cmd(cmd, timeout=DEFAULT_TIMEOUT):
    return await asyncio.to_thread(_run_cmd_sync, cmd, timeout)

def _battery_sync():
    try:
        result = subprocess.run(['rish', '-c', 'dumpsys battery | grep level'], capture_output=True, text=True, timeout=5)
        for line in result.stdout.splitlines():
            if line.strip().startswith("level:"):
                try: return int(line.split(":")[1].strip())
                except: return -1
        return -1
    except: return -1

async def get_battery():
    return await asyncio.to_thread(_battery_sync)

def _get_roblox_pid_sync():
    try:
        result = subprocess.run(['rish', '-c', f'pidof {PACKAGE}'], capture_output=True, text=True, timeout=8)
        return result.stdout.strip()
    except: return ""

async def get_roblox_pid():
    return await asyncio.to_thread(_get_roblox_pid_sync)

def _is_process_alive_sync(pid_str):
    if not pid_str: return False
    try:
        for pid in pid_str.split():
            result = subprocess.run(['rish', '-c', f'cat /proc/{pid}/status 2>/dev/null | grep "^State:"'], capture_output=True, text=True, timeout=3)
            status = result.stdout.strip()
            if status and "zombie" not in status.lower() and "dead" not in status.lower():
                return True
        return False
    except: return False

async def is_process_alive(pid_str):
    return await asyncio.to_thread(_is_process_alive_sync, pid_str)

async def confirm_roblox_gone(rechecks=2, delay=5):
    for i in range(rechecks):
        pid = await get_roblox_pid()
        if pid and await is_process_alive(pid): return False
        if i < rechecks - 1: await asyncio.sleep(delay)
    return True

async def capture_and_check_disconnect():
    img_path = "/sdcard/rbx_watchdog.png"
    text = await run_cmd(
        f'screencap -p {img_path} && magick {img_path} -gravity Center -crop 40x40%+0+0 -resize 480x -colorspace Gray -threshold 50% png:- | tesseract stdin stdout --psm 3; rm -f {img_path}',
        timeout=20,
    )
    if any(w in text.lower() for w in DISCONNECT_KEYWORDS): return True
    text2 = await run_cmd(
        f'screencap -p {img_path} && magick {img_path} -gravity Center -crop 40x40%+0+0 -resize 480x -colorspace Gray -threshold 50% png:- | tesseract stdin stdout --psm 6; rm -f {img_path}',
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
    async with reconnect_lock:
        recent = [t for t in state.reconnect_timestamps if time.time() - t < 60]
        if recent:
            logger.info(f"[SKIP] Reconnect already in progress")
            return

        state.stats["crashes"] += 1
        state.reconnect_timestamps.append(time.time())
        state.last_crash_reason = reason
        state.last_crash_at = datetime.now()
        state.roblox_state = "reconnecting"
        
        logger.info(f"[RECONNECTOR] Trigger received: {reason}")

        m = re.search(r'/games/(\d+)', state.current_game_link)
        launch_url = f"roblox://placeId={m.group(1)}" if m else state.current_game_link

        max_attempts = 3
        backoff_delays = [0, 10, 20]
        relaunched = False

        for attempt in range(max_attempts):
            if attempt > 0:
                delay = backoff_delays[attempt]
                logger.info(f"[RECONNECTOR] Attempt {attempt + 1}/{max_attempts} after {delay}s backoff...")
                await asyncio.sleep(delay)
            else:
                logger.info(f"[RECONNECTOR] Attempt 1/{max_attempts}...")

            logger.info("[RECONNECTOR] Step 1: Force-stopping Roblox...")
            await run_cmd(f'am force-stop {PACKAGE}')
            await asyncio.sleep(1)

            pid_check = await get_roblox_pid()
            if pid_check:
                logger.info(f"[RECONNECTOR] Step 2: Killing PID {pid_check.split()[0]}...")
                await run_cmd(f'kill -9 {pid_check.split()[0]}')
                await asyncio.sleep(0.5)
            else:
                logger.info("[RECONNECTOR] Step 2: Roblox stopped cleanly")

            logger.info(f"[RECONNECTOR] Step 3: Launching Roblox ({launch_url})...")
            await run_cmd(f'am start -a android.intent.action.VIEW -d "{launch_url}"')

            logger.info("[RECONNECTOR] Step 4: Waiting for Roblox to start...")
            poll_deadline = time.time() + 30
            await asyncio.sleep(3)
            while time.time() < poll_deadline:
                pid = await get_roblox_pid()
                if pid and await is_process_alive(pid):
                    relaunched = True
                    break
                await asyncio.sleep(1.5)

            if relaunched:
                logger.info(f"[RECONNECTOR] Recovery successful on attempt {attempt + 1}!")
                break
            else:
                logger.warning(f"[RECONNECTOR] Attempt {attempt + 1} failed")

        state.consecutive_ocr_hits = 0
        state.last_reconnect_time = time.time()
        state.roblox_state = "loading" if relaunched else "offline"

# ============================================================
# FAST DISCONNECT CHECKER (5s interval)
# ============================================================
async def fast_disconnect_checker():
    logger.info("[STARTUP] Fast disconnect checker active (5s interval)")
    while True:
        await asyncio.sleep(5)
        if not state.watchdog_enabled: continue
        if state.last_reconnect_time > 0 and time.time() - state.last_reconnect_time < POST_RECONNECT_COOLDOWN_SEC: continue
        if state.roblox_state == "reconnecting": continue

        try:
            if os.path.exists(DISCONNECT_SIGNAL_FILE):
                with open(DISCONNECT_SIGNAL_FILE, 'r') as f: signal = f.read().strip()
                os.remove(DISCONNECT_SIGNAL_FILE)
                logger.warning(f"[FAST] Disconnect signal from Lua: {signal[:80]}")
                await reconnect_game(reason="lua_disconnect_signal")
                continue
        except: pass

        pid = await get_roblox_pid()
        if not pid: continue

        if await capture_and_check_disconnect():
            state.consecutive_ocr_hits += 1
            if state.consecutive_ocr_hits >= 2:
                logger.warning("[FAST] 2 consecutive disconnect detections — reconnecting")
                state.stats["kicks"] += 1
                await reconnect_game(reason="ocr_disconnect_fast")
                state.consecutive_ocr_hits = 0
        else:
            state.consecutive_ocr_hits = 0

# ============================================================
# WEBSOCKET MANAGER
# ============================================================
class WebSocketManager:
    def __init__(self):
        self.active_connections = []
        self._loop = asyncio.get_event_loop()
    async def connect(self, ws: WebSocket):
        await ws.accept()
        self.active_connections.append(ws)
    def disconnect(self, ws: WebSocket):
        if ws in self.active_connections: self.active_connections.remove(ws)
    async def broadcast(self, msg: dict):
        for c in self.active_connections[:]:
            try: await c.send_json(msg)
            except: self.disconnect(c)
    def broadcast_sync(self, msg: dict):
        if self._loop.is_running():
            asyncio.run_coroutine_threadsafe(self.broadcast(msg), self._loop)

ws_manager = WebSocketManager()
logger.addHandler(WebSocketLogHandler(ws_manager))

# ============================================================
# FASTAPI APP
# ============================================================
app = FastAPI(title="Reconnector API")
security = HTTPBearer()

def verify_token(credentials: HTTPAuthorizationCredentials = Security(security)):
    if credentials.credentials != AUTH_TOKEN:
        raise HTTPException(status_code=401, detail="Invalid token")

@app.get("/api/status")
async def get_status():
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
        "last_crash_reason": state.last_crash_reason,
        "last_reconnect": int(state.last_reconnect_time) if state.last_reconnect_time else 0,
        "optimizations": {
            "kill_bg": state.opt_kill_bg,
            "process_limit": state.opt_process_limit,
            "no_animations": state.opt_no_animations,
            "force_gpu": state.opt_force_gpu,
            "no_bluetooth": state.opt_no_bluetooth,
        }
    }

@app.post("/api/restart")
async def restart_roblox():
    asyncio.create_task(reconnect_game(reason="manual_restart", clear_cache=True))
    return {"status": "initiated"}

@app.get("/api/screenshot")
async def screenshot():
    img_path = "/sdcard/rbx_manual.png"
    await run_cmd(f'screencap -p {img_path}')
    try:
        import base64
        with open(img_path, 'rb') as f:
            img_data = base64.b64encode(f.read()).decode('utf-8')
        await run_cmd(f'rm -f {img_path}')
        return {"image": img_data}
    except Exception as e:
        return {"error": str(e)}

@app.post("/api/black-screen")
async def black_screen():
    html = '<html><body bgcolor="black"><div style="position:fixed;top:20px;right:20px;width:50px;height:50px;background:rgba(255,255,255,0.1);border-radius:50%;display:flex;align-items:center;justify-content:center;color:white;font-size:24px;cursor:pointer;" onclick="history.back()">×</div></body></html>'
    with open("/sdcard/black.html", "w") as f: f.write(html)
    await run_cmd('am start -a android.intent.action.VIEW -d "file:///sdcard/black.html" -t "text/html"')
    return {"status": "ok"}

@app.post("/api/brightness/{level}")
async def set_brightness(level: int):
    state.brightness_level = level
    await run_cmd(f'settings put system screen_brightness {level}')
    return {"status": "ok"}

@app.post("/api/watchdog/toggle")
async def toggle_watchdog():
    state.watchdog_enabled = not state.watchdog_enabled
    return {"status": "ok", "enabled": state.watchdog_enabled}

@app.post("/api/clear-anti-loop")
async def clear_anti_loop():
    state.reconnect_timestamps = []
    state.is_paused = False
    return {"status": "ok"}

@app.post("/api/optimize/{name}")
async def toggle_optimize(name: str, request: Request):
    data = await request.json()
    enabled = data.get("enabled", False)
    if name == "kill_bg": state.opt_kill_bg = enabled
    elif name == "process_limit": state.opt_process_limit = enabled
    elif name == "no_animations": state.opt_no_animations = enabled
    elif name == "force_gpu": state.opt_force_gpu = enabled
    elif name == "no_bluetooth": state.opt_no_bluetooth = enabled
    return {"status": "ok"}

class GameLinkModel(BaseModel):
    url: str

@app.post("/api/game-link")
async def set_game_link(data: GameLinkModel):
    state.current_game_link = data.url
    return {"status": "ok"}

@app.post("/api/interval/{minutes}")
async def set_interval(minutes: int):
    state.watchdog_interval_minutes = minutes
    return {"status": "ok"}

@app.get("/api/logs")
async def get_logs():
    try:
        with open(LOG_FILE, 'r') as f: lines = f.readlines()[-100:]
        return {"logs": lines}
    except: return {"logs": []}

@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await ws_manager.connect(ws)
    try:
        while True:
            await asyncio.sleep(5)
            status = await get_status()
            await ws.send_json({"type": "status", "data": status, "timestamp": time.time()})
    except WebSocketDisconnect:
        ws_manager.disconnect(ws)
    except Exception:
        ws_manager.disconnect(ws)

# ============================================================
# STARTUP
# ============================================================
@app.on_event("startup")
async def startup_event():
    logger.info("[STARTUP] Reconnector API starting...")
    logger.info(f"[STARTUP] Auth token: {AUTH_TOKEN[:4]}...")
    asyncio.create_task(fast_disconnect_checker())

if __name__ == "__main__":
    uvicorn.run(app, host=HOST, port=PORT)
