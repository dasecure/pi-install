#!/bin/bash
# Pi Zero-Trust Agent v3.0 - Self-Contained Installer
# No git clone needed — all files are embedded.
#
# Pi:  curl -fsSL https://install.dasecure.com | sudo bash -s -- --iotpush-key KEY --iotpush-topic TOPIC --tailscale-key TSKEY
# VPS: curl -fsSL https://install.dasecure.com | sudo bash -s -- --no-tailscale --hostname my-vps

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}"
echo "╔════════════════════════════════════════════════════════╗"
echo "║         Pi Zero-Trust Agent v3.0 - Installer          ║"
echo "╚════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Parse arguments
IOTPUSH_KEY=""
IOTPUSH_TOPIC=""
TAILSCALE_KEY=""
HOSTNAME="${HOSTNAME:-zerotrust-pi}"
ENABLE_WATCHDOG=false
NO_TAILSCALE=false
UPDATE_MODE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --iotpush-key)
      IOTPUSH_KEY="$2"
      shift 2
      ;;
    --iotpush-topic)
      IOTPUSH_TOPIC="$2"
      shift 2
      ;;
    --tailscale-key)
      TAILSCALE_KEY="$2"
      shift 2
      ;;
    --hostname)
      HOSTNAME="$2"
      shift 2
      ;;
    --watchdog)
      ENABLE_WATCHDOG=true
      shift
      ;;
    --no-tailscale)
      NO_TAILSCALE=true
      shift
      ;;
    --api-token)
      CUSTOM_API_TOKEN="$2"
      shift 2
      ;;
    --update)
      UPDATE_MODE=true
      shift
      ;;
    *)
      echo -e "${RED}Unknown option: $1${NC}"
      exit 1
      ;;
  esac
done

# ============ Update Mode: skip config/Tailscale, just update files ============
if [ "$UPDATE_MODE" = true ]; then
  echo -e "${BLUE}Update mode: refreshing agent files only...${NC}"
  echo ""
  STEP=0
  TOTAL_STEPS=3
fi

if [ "$UPDATE_MODE" = false ]; then
# Validate required args
if [ "$NO_TAILSCALE" = false ] && { [ -z "$IOTPUSH_KEY" ] || [ -z "$IOTPUSH_TOPIC" ] || [ -z "$TAILSCALE_KEY" ]; }; then
  echo -e "${RED}Missing required arguments!${NC}"
  echo ""
  echo "Usage (Pi with Tailscale):"
  echo "  curl -fsSL https://install.dasecure.com | sudo bash -s -- \\"
  echo "    --iotpush-key YOUR_API_KEY \\"
  echo "    --iotpush-topic YOUR_TOPIC \\"
  echo "    --tailscale-key YOUR_TAILSCALE_AUTH_KEY \\"
  echo "    --hostname pi-name"
  echo ""
  echo "Usage (VPS without Tailscale):"
  echo "  curl -fsSL https://install.dasecure.com | sudo bash -s -- \\"
  echo "    --no-tailscale --hostname my-vps"
  echo ""
  echo "Get your keys:"
  echo "  - iotPush: https://iotpush.com/settings"
  echo "  - Tailscale: https://login.tailscale.com/admin/settings/keys"
  exit 1
fi

# Generate or use custom API token
if [ -n "$CUSTOM_API_TOKEN" ]; then
  API_TOKEN="$CUSTOM_API_TOKEN"
else
  API_TOKEN=$(openssl rand -hex 32)
fi

# Determine number of steps
if [ "$NO_TAILSCALE" = true ]; then
  TOTAL_STEPS=5
  echo -e "${BLUE}Mode: VPS (no Tailscale)${NC}"
else
  TOTAL_STEPS=7
  echo -e "${BLUE}Mode: Pi (Tailscale)${NC}"
fi
echo ""

# ============ Step 1: Config ============
STEP=1
echo -e "${YELLOW}[$STEP/$TOTAL_STEPS] Creating config...${NC}"
mkdir -p /etc/pi-zero-trust

if [ "$NO_TAILSCALE" = true ]; then
cat > /etc/pi-zero-trust/.env << EOF
IOTPUSH_API_KEY=${IOTPUSH_KEY}
IOTPUSH_TOPIC=${IOTPUSH_TOPIC}
PI_API_TOKEN=${API_TOKEN}
TAILSCALE_ONLY=false
EOF
else
cat > /etc/pi-zero-trust/.env << EOF
IOTPUSH_API_KEY=${IOTPUSH_KEY}
IOTPUSH_TOPIC=${IOTPUSH_TOPIC}
TAILSCALE_AUTH_KEY=${TAILSCALE_KEY}
PI_API_TOKEN=${API_TOKEN}
TAILSCALE_ONLY=true
EOF
fi
chmod 600 /etc/pi-zero-trust/.env

cat > /etc/pi-zero-trust/settings.json << EOF
{
  "notifications_enabled": true,
  "notify_on_boot": true,
  "notify_on_reboot": true,
  "notify_on_update": true,
  "notify_cooldown_minutes": 5,
  "tailscale_only": $([ "$NO_TAILSCALE" = true ] && echo "false" || echo "true")
}
EOF
chmod 600 /etc/pi-zero-trust/settings.json

echo -e "  ${GREEN}✓${NC} /etc/pi-zero-trust/.env"
echo -e "  ${GREEN}✓${NC} /etc/pi-zero-trust/settings.json"

# ============ Step 2: Notification helper ============
STEP=$((STEP + 1))
if [ -n "$IOTPUSH_KEY" ] && [ -n "$IOTPUSH_TOPIC" ]; then
  echo -e "${YELLOW}[$STEP/$TOTAL_STEPS] Creating notification helper...${NC}"
  cat > /usr/local/bin/pi-notify << 'SCRIPT'
#!/bin/bash
source /etc/pi-zero-trust/.env
curl -s -d "$1" \
  -H "Authorization: Bearer $IOTPUSH_API_KEY" \
  https://www.iotpush.com/api/push/$IOTPUSH_TOPIC
SCRIPT
  chmod +x /usr/local/bin/pi-notify
  echo -e "  ${GREEN}✓${NC} /usr/local/bin/pi-notify"
else
  echo -e "${YELLOW}[$STEP/$TOTAL_STEPS] Skipping notifications (no iotPush keys)${NC}"
  echo '#!/bin/bash' > /usr/local/bin/pi-notify
  echo 'true' >> /usr/local/bin/pi-notify
  chmod +x /usr/local/bin/pi-notify
fi

# ============ Step 3-4: Tailscale (if enabled) ============
if [ "$NO_TAILSCALE" = false ]; then
  STEP=$((STEP + 1))
  echo -e "${YELLOW}[$STEP/$TOTAL_STEPS] Installing Tailscale...${NC}"
  if ! command -v tailscale &> /dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
    echo -e "  ${GREEN}✓${NC} Tailscale installed"
  else
    echo -e "  ${BLUE}→${NC} Tailscale already installed"
  fi

  STEP=$((STEP + 1))
  echo -e "${YELLOW}[$STEP/$TOTAL_STEPS] Connecting Tailscale...${NC}"
  tailscale up --authkey="$TAILSCALE_KEY" --ssh --hostname="$HOSTNAME" || true
  TS_IP=$(tailscale ip -4 2>/dev/null || echo "pending")
  echo -e "  ${GREEN}✓${NC} Tailscale IP: $TS_IP"

  pi-notify "🔒 Agent installing on $HOSTNAME ($TS_IP)" || true
else
  TS_IP="N/A"
fi

fi # end UPDATE_MODE=false block

# Clean up stale .git directory so version-based update checks work
if [ -d /opt/pi-utility/.git ]; then
  rm -rf /opt/pi-utility/.git
fi

# ============ Step: Write agent files (self-contained) ============
STEP=$((STEP + 1))
echo -e "${YELLOW}[$STEP/$TOTAL_STEPS] Writing agent files...${NC}"
mkdir -p /opt/pi-utility/pi-service

# --- pi-monitor.py (embedded) ---
cat > /opt/pi-utility/pi-service/pi-monitor.py << 'PYEOF'
#!/usr/bin/env python3
"""
Pi Zero-Trust Agent v3.0
Lightweight, secure agent for system monitoring and log collection.
"""

import os
import json
import socket
import subprocess
import asyncio
import secrets
import logging
from pathlib import Path
from datetime import datetime, timedelta
from typing import Optional
from contextlib import asynccontextmanager

import psutil
import httpx
from fastapi import FastAPI, HTTPException, Request, Depends, Header
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
from dotenv import load_dotenv

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger("pi-agent")

AGENT_VERSION = "3.0.1"
INSTALL_URL = "https://raw.githubusercontent.com/dasecure/pi-install/main/install.sh"

ENV_PATH = Path("/etc/pi-zero-trust/.env")
load_dotenv(ENV_PATH)

class Config:
    IOTPUSH_API_KEY: str = os.getenv("IOTPUSH_API_KEY", "")
    API_TOKEN: str = os.getenv("PI_API_TOKEN", "")
    TAILSCALE_ONLY: bool = os.getenv("TAILSCALE_ONLY", "true").lower() == "true"
    LOG_PATH: Path = Path("/var/log/pi-monitor")
    REPO_PATH: Path = Path("/opt/pi-utility")
    MAX_RETRIES: int = 3
    RETRY_DELAY: float = 2.0

config = Config()
config.LOG_PATH.mkdir(parents=True, exist_ok=True)

class SettingsModel(BaseModel):
    notifications_enabled: bool = True
    notify_on_boot: bool = True
    notify_on_reboot: bool = True
    notify_on_update: bool = True
    notify_cooldown_minutes: int = 5
    tailscale_only: bool = True
    anthropic_api_key: str = ""
    iotpush_api_key: str = ""
    iotpush_topic: str = ""

class GeneratePageRequest(BaseModel):
    prompt: str

class SavePageRequest(BaseModel):
    name: str
    html: str

def sd_notify(state: str):
    sock_path = os.environ.get("NOTIFY_SOCKET")
    if not sock_path:
        return
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        sock.connect(sock_path)
        sock.sendall(state.encode())
        sock.close()
    except Exception:
        pass

async def watchdog_loop():
    while True:
        sd_notify("WATCHDOG=1")
        await asyncio.sleep(30)

SETTINGS_PATH = Path("/etc/pi-zero-trust/settings.json")

def load_settings() -> SettingsModel:
    try:
        if SETTINGS_PATH.exists():
            with open(SETTINGS_PATH) as f:
                data = json.load(f)
                # Seed iotpush from env vars if not in saved settings
                if not data.get("iotpush_api_key"):
                    data["iotpush_api_key"] = os.getenv("IOTPUSH_API_KEY", "")
                if not data.get("iotpush_topic"):
                    data["iotpush_topic"] = os.getenv("IOTPUSH_TOPIC", "")
                s = SettingsModel(**data)
                config.TAILSCALE_ONLY = s.tailscale_only
                return s
    except Exception as e:
        logger.error(f"Failed to load settings: {e}")
    return SettingsModel(
        tailscale_only=config.TAILSCALE_ONLY,
        iotpush_api_key=os.getenv("IOTPUSH_API_KEY", ""),
        iotpush_topic=os.getenv("IOTPUSH_TOPIC", ""),
    )

def save_settings(settings: SettingsModel) -> bool:
    try:
        SETTINGS_PATH.parent.mkdir(parents=True, exist_ok=True)
        with open(SETTINGS_PATH, 'w') as f:
            json.dump(settings.model_dump(), f, indent=2)
        config.TAILSCALE_ONLY = settings.tailscale_only
        return True
    except Exception as e:
        logger.error(f"Failed to save settings: {e}")
        return False

_settings = load_settings()
_last_notify_times: dict[str, datetime] = {}

PAGES_DIR = Path("/var/www/pi-pages")
PAGES_MANIFEST = PAGES_DIR / "pages.json"
_page_server_process: Optional[subprocess.Popen] = None

def slugify(name: str) -> str:
    import re
    slug = re.sub(r'[^a-z0-9]+', '-', name.lower()).strip('-')
    return slug or 'page'

def load_pages_manifest() -> list[dict]:
    try:
        if PAGES_MANIFEST.exists():
            with open(PAGES_MANIFEST) as f:
                return json.load(f)
    except Exception as e:
        logger.error(f"Failed to load pages manifest: {e}")
    return []

def save_pages_manifest(pages: list[dict]) -> bool:
    try:
        PAGES_DIR.mkdir(parents=True, exist_ok=True)
        with open(PAGES_MANIFEST, 'w') as f:
            json.dump(pages, f, indent=2)
        return True
    except Exception as e:
        logger.error(f"Failed to save pages manifest: {e}")
        return False

async def notify_iotpush(message: str, title: str = "Pi Zero-Trust", force: bool = False, bypass_cooldown: bool = False) -> bool:
    global _settings, _last_notify_times
    if not force and not _settings.notifications_enabled:
        return False
    cooldown = _settings.notify_cooldown_minutes
    if cooldown > 0 and not bypass_cooldown:
        dedup_key = message[:20]
        now = datetime.now()
        last_sent = _last_notify_times.get(dedup_key)
        if last_sent and (now - last_sent) < timedelta(minutes=cooldown):
            return False
        _last_notify_times[dedup_key] = now
    api_key = _settings.iotpush_api_key or os.getenv("IOTPUSH_API_KEY", "")
    topic = _settings.iotpush_topic or os.getenv("IOTPUSH_TOPIC", "")
    if not api_key or not topic:
        logger.warning("iotPush not configured")
        return False
    for attempt in range(config.MAX_RETRIES):
        try:
            async with httpx.AsyncClient() as client:
                response = await client.post(
                    f"https://www.iotpush.com/api/push/{topic}",
                    headers={"Authorization": f"Bearer {api_key}"},
                    content=message, timeout=10
                )
                if response.status_code == 200:
                    logger.info(f"iotPush sent: {message[:50]}")
                    return True
        except Exception as e:
            logger.error(f"iotPush error (attempt {attempt + 1}): {e}")
        if attempt < config.MAX_RETRIES - 1:
            await asyncio.sleep(config.RETRY_DELAY * (attempt + 1))
    return False

@asynccontextmanager
async def lifespan(app: FastAPI):
    global _settings
    logger.info("Pi Agent starting up...")
    sd_notify("READY=1")
    PAGES_DIR.mkdir(parents=True, exist_ok=True)
    watchdog_task = asyncio.create_task(watchdog_loop())
    ts_ip = get_tailscale_ip()
    hostname = os.uname().nodename
    if _settings.notifications_enabled and _settings.notify_on_boot:
        boot_msg = f"🟢 {hostname} online"
        if ts_ip:
            boot_msg += f" | {ts_ip}:8080"
        await notify_iotpush(boot_msg)
    yield
    global _page_server_process
    if _page_server_process is not None:
        _page_server_process.terminate()
        try:
            _page_server_process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            _page_server_process.kill()
        _page_server_process = None
    watchdog_task.cancel()
    logger.info("Pi Agent shutting down...")
    if _settings.notifications_enabled and _settings.notify_on_boot:
        await notify_iotpush(f"🔴 {hostname} offline")

app = FastAPI(title="Pi Zero-Trust Agent", version="3.0.0", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_credentials=True, allow_methods=["*"], allow_headers=["*"])

def get_tailscale_ip() -> Optional[str]:
    try:
        result = subprocess.run(["tailscale", "status", "--json"], capture_output=True, text=True)
        if result.returncode == 0:
            status = json.loads(result.stdout)
            return status.get("Self", {}).get("TailscaleIPs", [None])[0]
    except Exception:
        pass
    return None

def is_tailscale_request(request: Request) -> bool:
    client_ip = request.client.host if request.client else ""
    return client_ip.startswith("100.")

async def verify_auth(request: Request, authorization: Optional[str] = Header(None), x_api_token: Optional[str] = Header(None)):
    if request.url.path in ["/health", "/"]:
        return True
    if is_tailscale_request(request):
        return True
    if config.TAILSCALE_ONLY:
        raise HTTPException(status_code=403, detail="Access denied: Only Tailscale connections allowed")
    token = x_api_token or (authorization.replace("Bearer ", "") if authorization else None)
    if not config.API_TOKEN:
        logger.warning("No API_TOKEN configured - open mode!")
        return True
    if not token or not secrets.compare_digest(token, config.API_TOKEN):
        raise HTTPException(status_code=401, detail="Invalid or missing API token")
    return True

def format_uptime(seconds: float) -> str:
    days = int(seconds // 86400)
    hours = int((seconds % 86400) // 3600)
    minutes = int((seconds % 3600) // 60)
    parts = []
    if days > 0: parts.append(f"{days}d")
    if hours > 0: parts.append(f"{hours}h")
    parts.append(f"{minutes}m")
    return " ".join(parts)

def get_pi_model() -> str:
    try: return Path("/proc/device-tree/model").read_text().strip().rstrip('\x00')
    except Exception: return "Unknown"

def get_pi_serial() -> str:
    try: return Path("/proc/device-tree/serial-number").read_text().strip().rstrip('\x00')
    except Exception: return "Unknown"

def get_cpu_temperature() -> Optional[float]:
    try:
        temps = psutil.sensors_temperatures()
        for name in ["cpu_thermal", "cpu-thermal", "coretemp"]:
            if name in temps and temps[name]:
                return round(temps[name][0].current, 1)
    except Exception:
        pass
    return None

def get_tailscale_info() -> dict:
    try:
        result = subprocess.run(["tailscale", "status", "--json"], capture_output=True, text=True, timeout=5)
        if result.returncode == 0:
            status = json.loads(result.stdout)
            self_status = status.get("Self", {})
            ips = self_status.get("TailscaleIPs", [])
            dns = self_status.get("DNSName", "")
            return {"ip": ips[0] if ips else "N/A", "hostname": dns.rstrip(".") if dns else "N/A"}
    except Exception:
        pass
    return {"ip": "N/A", "hostname": "N/A"}

@app.get("/health")
async def health_check():
    return {"status": "healthy", "hostname": os.uname().nodename, "uptime": format_uptime(psutil.boot_time()), "version": "3.0.0"}

@app.get("/", dependencies=[Depends(verify_auth)])
async def root():
    return {"service": "Pi Zero-Trust Agent", "version": "3.0.0", "hostname": os.uname().nodename, "endpoints": ["/health", "/stats", "/system", "/logs", "/settings"]}

@app.get("/stats", dependencies=[Depends(verify_auth)])
async def get_stats():
    try:
        cpu = psutil.cpu_percent(interval=0.5)
        memory = psutil.virtual_memory()
        disk = psutil.disk_usage("/")
        net = psutil.net_io_counters()
        boot = psutil.boot_time()
        uptime = datetime.now().timestamp() - boot
        temp = get_cpu_temperature()
        ts = get_tailscale_info()
        load = [round(x, 2) for x in os.getloadavg()]
        return {
            "hostname": os.uname().nodename, "uptime_seconds": round(uptime, 1), "uptime_human": format_uptime(uptime),
            "cpu_percent": cpu, "cpu_count": psutil.cpu_count(),
            "memory_total_mb": round(memory.total / 1048576, 1), "memory_used_mb": round(memory.used / 1048576, 1),
            "memory_available_mb": round(memory.available / 1048576, 1), "memory_percent": memory.percent,
            "disk_total_gb": round(disk.total / 1073741824, 1), "disk_used_gb": round(disk.used / 1073741824, 1),
            "disk_free_gb": round(disk.free / 1073741824, 1), "disk_percent": round(disk.percent, 1),
            "temperature_c": temp, "load_average": load,
            "tailscale_ip": ts["ip"], "tailscale_hostname": ts["hostname"],
            "network_sent_mb": round(net.bytes_sent / 1048576, 1), "network_recv_mb": round(net.bytes_recv / 1048576, 1),
            "timestamp": datetime.now().isoformat()
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/system", dependencies=[Depends(verify_auth)])
async def get_system():
    import platform
    ts_version = None
    try:
        r = subprocess.run(["tailscale", "version"], capture_output=True, text=True, timeout=5)
        if r.returncode == 0: ts_version = r.stdout.strip().split('\n')[0]
    except Exception: pass
    return {
        "hostname": os.uname().nodename, "platform": platform.system(), "platform_release": platform.release(),
        "platform_version": platform.version(), "architecture": platform.machine(),
        "processor": platform.processor() or "N/A", "python_version": platform.python_version(),
        "boot_time": datetime.fromtimestamp(psutil.boot_time()).isoformat(),
        "tailscale_version": ts_version, "pi_model": get_pi_model(), "pi_serial": get_pi_serial()
    }

@app.get("/logs/{log_type}", dependencies=[Depends(verify_auth)])
async def get_logs(log_type: str, lines: int = 100):
    allowed = {
        "system": ["journalctl", "-n", str(lines), "--no-pager"],
        "auth": ["journalctl", "-n", str(lines), "--no-pager", "-u", "ssh"],
        "pi-monitor": ["journalctl", "-n", str(lines), "--no-pager", "-u", "pi-monitor"],
        "tailscale": ["journalctl", "-n", str(lines), "--no-pager", "-u", "tailscaled"],
        "firewall": ["journalctl", "-n", str(lines), "--no-pager", "-k", "--grep=UFW"],
    }
    if log_type not in allowed:
        raise HTTPException(status_code=400, detail=f"Invalid log type. Allowed: {list(allowed.keys())}")
    try:
        result = subprocess.run(allowed[log_type], capture_output=True, text=True, timeout=10)
        return {"success": True, "log_type": log_type, "lines": result.stdout.strip().split('\n'), "count": lines}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/logs/stream/{log_type}", dependencies=[Depends(verify_auth)])
async def stream_logs(log_type: str):
    allowed = {
        "system": ["journalctl", "-f", "--no-pager"],
        "auth": ["journalctl", "-f", "--no-pager", "-u", "ssh"],
        "pi-monitor": ["journalctl", "-f", "--no-pager", "-u", "pi-monitor"],
        "tailscale": ["journalctl", "-f", "--no-pager", "-u", "tailscaled"],
    }
    if log_type not in allowed:
        raise HTTPException(status_code=400, detail=f"Invalid log type. Allowed: {list(allowed.keys())}")
    async def generate():
        process = await asyncio.create_subprocess_exec(*allowed[log_type], stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        try:
            async for line in process.stdout:
                yield f"data: {line.decode().strip()}\n\n"
        finally:
            process.terminate()
            await process.wait()
    return StreamingResponse(generate(), media_type="text/event-stream")

@app.get("/check-update", dependencies=[Depends(verify_auth)])
async def check_update():
    import re as _re
    repo = config.REPO_PATH
    git_dir = repo / ".git"
    if git_dir.exists():
        try:
            subprocess.run(["git", "fetch", "origin"], cwd=repo, capture_output=True, text=True, timeout=15)
            current = subprocess.run(["git", "log", "-1", "--format=%H|%s|%ai"], cwd=repo, capture_output=True, text=True)
            latest = subprocess.run(["git", "log", "-1", "origin/main", "--format=%H|%s|%ai"], cwd=repo, capture_output=True, text=True)
            behind = subprocess.run(["git", "rev-list", "--count", "HEAD..origin/main"], cwd=repo, capture_output=True, text=True)
            c_parts = current.stdout.strip().split("|")
            l_parts = latest.stdout.strip().split("|")
            count = int(behind.stdout.strip()) if behind.returncode == 0 else 0
            return {
                "update_available": count > 0, "commits_behind": count,
                "current_version": c_parts[0][:7] if c_parts else "—",
                "current_message": c_parts[1] if len(c_parts) > 1 else "",
                "current_date": c_parts[2] if len(c_parts) > 2 else "",
                "latest_version": l_parts[0][:7] if l_parts else "",
                "latest_message": l_parts[1] if len(l_parts) > 1 else "",
                "latest_date": l_parts[2] if len(l_parts) > 2 else "",
            }
        except Exception as e:
            return {"update_available": False, "commits_behind": 0, "current_version": "—", "current_message": str(e), "current_date": "", "latest_version": "", "latest_message": "", "latest_date": ""}
    try:
        async with httpx.AsyncClient() as client:
            resp = await client.get(INSTALL_URL, timeout=15)
            if resp.status_code == 200:
                match = _re.search(r'AGENT_VERSION\s*=\s*["\']([^"\']+)["\']', resp.text)
                remote_version = match.group(1) if match else "unknown"
                update_available = remote_version != AGENT_VERSION
                return {
                    "update_available": update_available, "commits_behind": 1 if update_available else 0,
                    "current_version": AGENT_VERSION, "current_message": "Self-contained install", "current_date": "",
                    "latest_version": remote_version, "latest_message": "Latest from pi-install" if update_available else "Up to date", "latest_date": "",
                }
    except Exception as e:
        logger.error(f"Script-based update check failed: {e}")
    return {"update_available": False, "commits_behind": 0, "current_version": AGENT_VERSION, "current_message": "Self-contained install", "current_date": "", "latest_version": "", "latest_message": "Could not check remote", "latest_date": ""}

@app.post("/update", dependencies=[Depends(verify_auth)])
async def update_agent():
    repo = config.REPO_PATH
    git_dir = repo / ".git"
    if git_dir.exists():
        try:
            pull = subprocess.run(["git", "pull", "origin", "main"], cwd=repo, capture_output=True, text=True, timeout=30)
            if pull.returncode == 0:
                subprocess.run([str(repo / "venv/bin/pip"), "install", "-q", "-r", str(repo / "pi-service/requirements.txt")], capture_output=True, text=True, timeout=60)
                subprocess.Popen(["systemctl", "restart", "pi-monitor"])
                return {"success": True, "message": "Update applied, restarting agent...", "output": pull.stdout.strip()}
            logger.warning(f"git pull failed, falling back to script update: {pull.stderr.strip()}")
        except Exception as e:
            logger.warning(f"git update failed, falling back to script update: {e}")
    try:
        result = subprocess.run(["bash", "-c", f"curl -fsSL {INSTALL_URL} | bash -s -- --update"], capture_output=True, text=True, timeout=120)
        if result.returncode != 0:
            return {"success": False, "message": result.stderr.strip()[-500:], "output": result.stdout.strip()[-500:]}
        subprocess.Popen(["systemctl", "restart", "pi-monitor"])
        return {"success": True, "message": "Update applied, restarting agent...", "output": result.stdout.strip()[-500:]}
    except Exception as e:
        return {"success": False, "message": str(e), "output": None}

@app.post("/reboot", dependencies=[Depends(verify_auth)])
async def reboot():
    if _settings.notifications_enabled and _settings.notify_on_reboot:
        await notify_iotpush(f"🔄 {os.uname().nodename} rebooting")
    subprocess.Popen(["sudo", "reboot"])
    return {"success": True, "message": "Rebooting..."}

@app.post("/shutdown", dependencies=[Depends(verify_auth)])
async def shutdown():
    if _settings.notifications_enabled and _settings.notify_on_reboot:
        await notify_iotpush(f"⏹️ {os.uname().nodename} shutting down")
    subprocess.Popen(["sudo", "shutdown", "-h", "now"])
    return {"success": True, "message": "Shutting down..."}

@app.post("/uninstall", dependencies=[Depends(verify_auth)])
async def uninstall():
    hostname = os.uname().nodename
    if _settings.notifications_enabled:
        await notify_iotpush(f"🗑️ {hostname} agent uninstalling", force=True)
    uninstall_script = Path("/opt/pi-utility/uninstall.sh")
    if not uninstall_script.exists():
        raise HTTPException(status_code=404, detail="Uninstall script not found")
    subprocess.Popen(["bash", str(uninstall_script)])
    return {"success": True, "message": "Uninstalling agent..."}

@app.get("/settings", dependencies=[Depends(verify_auth)])
async def get_settings():
    return _settings.model_dump()

@app.post("/settings", dependencies=[Depends(verify_auth)])
async def update_settings(new_settings: SettingsModel):
    global _settings
    _settings = new_settings
    if save_settings(_settings):
        return {"success": True, "settings": _settings.model_dump()}
    raise HTTPException(status_code=500, detail="Failed to save settings")

@app.post("/settings/notifications", dependencies=[Depends(verify_auth)])
async def toggle_notifications(enabled: bool = True):
    global _settings
    _settings.notifications_enabled = enabled
    if save_settings(_settings):
        if enabled: await notify_iotpush("🔔 Notifications enabled", force=True)
        return {"success": True, "notifications_enabled": enabled}
    raise HTTPException(status_code=500, detail="Failed to save settings")

@app.post("/settings/test-notification", dependencies=[Depends(verify_auth)])
async def test_notification():
    success = await notify_iotpush("🧪 Test notification from Pi!", force=True, bypass_cooldown=True)
    return {"success": success}

class NotifyRequest(BaseModel):
    title: str = "Pi Zero-Trust"
    message: str


@app.post("/notify", dependencies=[Depends(verify_auth)])
async def send_notify(req: NotifyRequest):
    text = f"{req.title}: {req.message}" if req.title != "Pi Zero-Trust" else req.message
    success = await notify_iotpush(text, title=req.title, force=True, bypass_cooldown=True)
    return {"success": success}

@app.post("/ai/generate", dependencies=[Depends(verify_auth)])
async def generate_page(req: GeneratePageRequest):
    api_key = _settings.anthropic_api_key
    if not api_key:
        raise HTTPException(status_code=400, detail="Anthropic API key not configured. Set it in Settings.")
    system_prompt = "You are a web page generator. Generate a complete, self-contained HTML page with inline CSS and no external dependencies. Use modern, responsive design with clean typography and appealing colors. The page should work perfectly on both desktop and mobile. Return ONLY the raw HTML code, no explanation or markdown fences."
    try:
        async with httpx.AsyncClient() as client:
            response = await client.post("https://api.anthropic.com/v1/messages", headers={"x-api-key": api_key, "anthropic-version": "2023-06-01", "content-type": "application/json"}, json={"model": "claude-sonnet-4-20250514", "max_tokens": 4096, "system": system_prompt, "messages": [{"role": "user", "content": req.prompt}]}, timeout=60)
        if response.status_code != 200:
            detail = response.json().get("error", {}).get("message", response.text)
            raise HTTPException(status_code=502, detail=f"Claude API error: {detail}")
        data = response.json()
        html = data["content"][0]["text"]
        if html.startswith("```"): html = html.split("\n", 1)[1]
        if html.endswith("```"): html = html.rsplit("```", 1)[0]
        return {"success": True, "html": html.strip()}
    except httpx.TimeoutException:
        raise HTTPException(status_code=504, detail="Claude API timeout — try a simpler prompt")
    except HTTPException: raise
    except Exception as e:
        logger.error(f"AI generation error: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/pages", dependencies=[Depends(verify_auth)])
async def list_pages():
    return {"success": True, "pages": load_pages_manifest()}

@app.post("/pages", dependencies=[Depends(verify_auth)])
async def save_page(req: SavePageRequest):
    PAGES_DIR.mkdir(parents=True, exist_ok=True)
    slug = slugify(req.name)
    html_path = PAGES_DIR / f"{slug}.html"
    pages = load_pages_manifest()
    existing = next((p for p in pages if p["slug"] == slug), None)
    if existing:
        existing["name"] = req.name
        existing["created_at"] = datetime.now().isoformat()
    else:
        pages.append({"name": req.name, "slug": slug, "created_at": datetime.now().isoformat(), "is_active": False})
    html_path.write_text(req.html)
    save_pages_manifest(pages)
    return {"success": True, "slug": slug}

@app.delete("/pages/{slug}", dependencies=[Depends(verify_auth)])
async def delete_page(slug: str):
    pages = load_pages_manifest()
    page = next((p for p in pages if p["slug"] == slug), None)
    if not page: raise HTTPException(status_code=404, detail="Page not found")
    html_path = PAGES_DIR / f"{slug}.html"
    if html_path.exists(): html_path.unlink()
    was_active = page.get("is_active", False)
    pages = [p for p in pages if p["slug"] != slug]
    if was_active:
        index_path = PAGES_DIR / "index.html"
        if index_path.exists(): index_path.unlink()
    save_pages_manifest(pages)
    return {"success": True}

@app.post("/pages/{slug}/activate", dependencies=[Depends(verify_auth)])
async def activate_page(slug: str):
    import shutil
    pages = load_pages_manifest()
    page = next((p for p in pages if p["slug"] == slug), None)
    if not page: raise HTTPException(status_code=404, detail="Page not found")
    html_path = PAGES_DIR / f"{slug}.html"
    if not html_path.exists(): raise HTTPException(status_code=404, detail="Page HTML file missing")
    for p in pages: p["is_active"] = (p["slug"] == slug)
    shutil.copy2(html_path, PAGES_DIR / "index.html")
    save_pages_manifest(pages)
    return {"success": True}

@app.get("/funnel/status", dependencies=[Depends(verify_auth)])
async def get_funnel_status():
    global _page_server_process
    server_alive = _page_server_process is not None and _page_server_process.poll() is None
    url = None
    if server_alive:
        try:
            ts_info = get_tailscale_info()
            hostname = ts_info.get("hostname", "")
            if hostname and hostname != "N/A": url = f"https://{hostname}"
        except Exception: pass
    return {"active": server_alive, "url": url}

@app.post("/funnel/on", dependencies=[Depends(verify_auth)])
async def funnel_on():
    global _page_server_process
    PAGES_DIR.mkdir(parents=True, exist_ok=True)
    index = PAGES_DIR / "index.html"
    if not index.exists():
        index.write_text("<html><body><h1>No page active</h1><p>Generate and activate a page from the PiControl app.</p></body></html>")
    if _page_server_process is None or _page_server_process.poll() is not None:
        _page_server_process = subprocess.Popen(["python3", "-m", "http.server", "3000", "--directory", str(PAGES_DIR)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        logger.info(f"Started page server on port 3000 (PID {_page_server_process.pid})")
    result = subprocess.run(["sudo", "tailscale", "funnel", "--bg", "3000"], capture_output=True, text=True, timeout=30)
    if result.returncode != 0:
        output = (result.stdout + "\n" + result.stderr).strip()
        logger.error(f"Funnel enable failed: {output}")
        return {"success": False, "message": output}
    ts_info = get_tailscale_info()
    hostname = ts_info.get("hostname", "")
    url = f"https://{hostname}" if hostname and hostname != "N/A" else None
    logger.info(f"Funnel enabled: {url}")
    return {"success": True, "url": url}

@app.post("/funnel/off", dependencies=[Depends(verify_auth)])
async def funnel_off():
    global _page_server_process
    subprocess.run(["sudo", "tailscale", "funnel", "--bg", "off"], capture_output=True, text=True, timeout=15)
    if _page_server_process is not None:
        _page_server_process.terminate()
        try: _page_server_process.wait(timeout=5)
        except subprocess.TimeoutExpired: _page_server_process.kill()
        _page_server_process = None
        logger.info("Page server stopped")
    return {"success": True}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080)
PYEOF

# --- requirements.txt (embedded) ---
cat > /opt/pi-utility/pi-service/requirements.txt << 'REQEOF'
fastapi>=0.109.0
uvicorn[standard]>=0.27.0
psutil>=5.9.0
httpx>=0.26.0
pydantic>=2.0.0
python-dotenv>=1.0.0
pyyaml>=6.0
REQEOF

# --- systemd service (embedded) ---
cat > /opt/pi-utility/pi-service/pi-monitor.service << 'SVCEOF'
[Unit]
Description=Pi Zero-Trust Agent v3.0
After=network-online.target tailscaled.service
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=notify
User=root
Group=root
WorkingDirectory=/opt/pi-utility/pi-service
Environment="PATH=/opt/pi-utility/venv/bin:/usr/local/bin:/usr/bin:/bin"
EnvironmentFile=-/etc/pi-zero-trust/.env
ExecStartPre=/opt/pi-utility/venv/bin/pip install -q -r /opt/pi-utility/pi-service/requirements.txt
ExecStart=/opt/pi-utility/venv/bin/uvicorn pi-monitor:app --host 0.0.0.0 --port 8080 --log-level info
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=30
TimeoutStartSec=30
TimeoutStopSec=10
WatchdogSec=90
NotifyAccess=all
StandardOutput=journal
StandardError=journal
SyslogIdentifier=pi-monitor
NoNewPrivileges=false
ProtectSystem=false
ProtectHome=read-only
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SVCEOF

# --- uninstall.sh (embedded) ---
cat > /opt/pi-utility/uninstall.sh << 'UNINSTEOF'
#!/bin/bash
# Pi Zero-Trust Agent - Uninstaller
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${RED}"
echo "╔════════════════════════════════════════════════════════╗"
echo "║         Pi Zero-Trust Agent - Uninstaller             ║"
echo "╚════════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "${YELLOW}[1/4] Stopping and disabling service...${NC}"
systemctl stop pi-monitor 2>/dev/null || true
systemctl disable pi-monitor 2>/dev/null || true
rm -f /etc/systemd/system/pi-monitor.service
systemctl daemon-reload
echo -e "  ${GREEN}✓${NC} Service removed"

echo -e "${YELLOW}[2/4] Removing agent files...${NC}"
rm -rf /opt/pi-utility
echo -e "  ${GREEN}✓${NC} /opt/pi-utility removed"

echo -e "${YELLOW}[3/4] Removing config...${NC}"
rm -rf /etc/pi-zero-trust
rm -rf /var/log/pi-monitor
rm -rf /var/www/pi-pages
echo -e "  ${GREEN}✓${NC} Config and data removed"

echo -e "${YELLOW}[4/4] Removing notification helper...${NC}"
rm -f /usr/local/bin/pi-notify
echo -e "  ${GREEN}✓${NC} pi-notify removed"

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════╗"
echo -e "║           Agent Uninstalled Successfully               ║"
echo -e "╚════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "Note: Tailscale was ${YELLOW}not${NC} removed. To remove it:"
echo "  sudo tailscale logout"
echo "  sudo apt remove tailscale"
echo ""
UNINSTEOF
chmod +x /opt/pi-utility/uninstall.sh

echo -e "  ${GREEN}✓${NC} /opt/pi-utility/pi-service/pi-monitor.py"
echo -e "  ${GREEN}✓${NC} /opt/pi-utility/pi-service/requirements.txt"
echo -e "  ${GREEN}✓${NC} /opt/pi-utility/pi-service/pi-monitor.service"
echo -e "  ${GREEN}✓${NC} /opt/pi-utility/uninstall.sh"

# ============ Step: Python environment ============
STEP=$((STEP + 1))
echo -e "${YELLOW}[$STEP/$TOTAL_STEPS] Setting up Python environment...${NC}"
apt-get update -qq
apt-get install -y -qq python3-venv python3-pip > /dev/null
if [ ! -d /opt/pi-utility/venv ]; then
  python3 -m venv /opt/pi-utility/venv
fi
/opt/pi-utility/venv/bin/pip install -q -r /opt/pi-utility/pi-service/requirements.txt
echo -e "  ${GREEN}✓${NC} Python venv + dependencies"

# ============ Step: Install service ============
STEP=$((STEP + 1))
echo -e "${YELLOW}[$STEP/$TOTAL_STEPS] Installing agent service...${NC}"
cp /opt/pi-utility/pi-service/pi-monitor.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable pi-monitor

# Update mode: skip restart here — the /update API endpoint restarts after responding
if [ "$UPDATE_MODE" = true ]; then
  echo -e "  ${GREEN}✓${NC} Agent files updated (restart pending)"
  exit 0
fi

systemctl restart pi-monitor
echo -e "  ${GREEN}✓${NC} pi-monitor.service enabled and started"

sleep 2

if systemctl is-active --quiet pi-monitor; then
  STATUS="${GREEN}running${NC}"
else
  STATUS="${RED}not running (check: journalctl -u pi-monitor -n 20)${NC}"
fi

# Final output
if [ "$NO_TAILSCALE" = false ]; then
  TS_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
  pi-notify "✅ Pi Zero-Trust Agent v3.0 ready! $HOSTNAME ($TS_IP:8080)" || true
  PUBLIC_IP="$TS_IP"
  DEVICE_TYPE="Pi"
else
  PUBLIC_IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "unknown")
  DEVICE_TYPE="VPS"
fi

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════╗"
echo -e "║           Agent Setup Complete!                        ║"
echo -e "╚════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Type:          ${GREEN}$DEVICE_TYPE${NC}"
echo -e "  Hostname:      ${GREEN}$HOSTNAME${NC}"
if [ "$NO_TAILSCALE" = false ]; then
echo -e "  Tailscale IP:  ${GREEN}$TS_IP${NC}"
fi
echo -e "  API Endpoint:  ${GREEN}http://$PUBLIC_IP:8080${NC}"
echo -e "  API Token:     ${YELLOW}$API_TOKEN${NC}"
echo -e "  Service:       $STATUS"
echo ""
echo -e "${BLUE}Add this device in the PiControl app:${NC}"
echo -e "  Type:     $DEVICE_TYPE"
echo -e "  Name:     $HOSTNAME"
echo -e "  Address:  $PUBLIC_IP"
echo -e "  Token:    $API_TOKEN"
echo ""
echo "Test it:"
echo "  curl http://$PUBLIC_IP:8080/health"
echo "  curl -H 'X-API-Token: $API_TOKEN' http://$PUBLIC_IP:8080/stats"
echo ""

# Generate QR code for PiControl app scanning
QR_DATA="{\"h\":\"$HOSTNAME\",\"a\":\"$PUBLIC_IP\",\"p\":8080,\"t\":\"$API_TOKEN\",\"d\":\"$(echo $DEVICE_TYPE | tr '[:upper:]' '[:lower:]')\"}"
/opt/pi-utility/venv/bin/pip install -q qrcode[pil] 2>/dev/null || true
/opt/pi-utility/venv/bin/python3 -c "
import sys
try:
    import qrcode
    qr = qrcode.QRCode(border=1)
    qr.add_data(sys.argv[1])
    qr.make(fit=True)
    qr.print_ascii(invert=True)
except ImportError:
    pass
" "$QR_DATA" 2>/dev/null && {
  echo ""
  echo -e "${BLUE}Scan this QR code in PiControl app → Settings → Scan QR${NC}"
  echo ""
} || true
