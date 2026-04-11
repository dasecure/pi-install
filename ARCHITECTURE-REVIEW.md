# Pi Zero-Trust Install — Architecture Review & Rewrite Proposal

**Date:** 2026-04-11
**Files:** `setup.sh` (1437 lines), `install.sh` (1086 lines)

---

## 1. Current Architecture

### Two-Script Design

```
setup.sh (TUI — interactive, gum-based menu)
  │
  ├── Calls install.sh with CLI flags for agent installation
  └── Also directly manages: Tailscale, VNC, iotPush, QR codes, updates, uninstall

install.sh (Headless — curl-pipeable installer)
  │
  ├── Parses CLI flags (--iotpush-key, --tailscale-key, --no-tailscale, etc.)
  ├── Has its own embedded: pi-monitor.py, requirements.txt, systemd service, uninstall.sh
  └── Can run standalone: curl ... | sudo bash -s -- --no-tailscale
```

### File Layout (after install)

```
/etc/pi-zero-trust/
  .env                     # IOTPUSH_KEY, IOTPUSH_TOPIC, API_TOKEN, HOSTNAME, TAILSCALE_ONLY
  settings.json            # Runtime settings (notifications, tailscale_only, etc.)

/opt/pi-utility/
  pi-service/
    pi-monitor.py          # FastAPI agent (~500 lines, EMBEDDED in install.sh)
    requirements.txt       # Python deps (also embedded)
    pi-monitor.service     # systemd unit (also embedded)
  venv/                    # Python virtualenv
  uninstall.sh             # Uninstaller (also embedded)

/var/log/pi-monitor/       # Log dir
/var/www/pi-pages/         # AI-generated HTML pages
/usr/local/bin/pi-notify   # Shell helper for push notifications
/etc/systemd/system/pi-monitor.service  # Installed systemd unit
```

### Pi-Monitor Agent (FastAPI)

Embedded Python app serving:
- `/health` — unauthenticated health check
- `/stats` — system stats (CPU, RAM, disk, temp, network)
- `/system` — platform info, Tailscale version, Pi model/serial
- `/logs/{type}` — journal log fetching (system, auth, pi-monitor, tailscale, firewall)
- `/logs/stream/{type}` — SSE log streaming
- `/settings` — CRUD for runtime settings
- `/notify` — push notification via iotPush
- `/ai/generate` — AI HTML page generation (calls Anthropic Claude)
- `/pages` — CRUD for AI-generated HTML pages
- `/funnel/*` — Tailscale Funnel control (serve pages publicly)
- `/check-update`, `/update` — Self-update
- `/reboot`, `/shutdown`, `/uninstall` — System control

Auth: API token OR Tailscale IP (100.x.x.x auto-trusted)

---

## 2. Problems Found

### Critical

| # | Issue | Impact |
|---|-------|--------|
| C1 | **Embedded Python in heredoc** — ~500 lines of pi-monitor.py live inside install.sh as a `cat > file << 'PYEOF'` block. Impossible to lint, test, or get IDE support for. | Maintenance nightmare, syntax errors silently propagated |
| C2 | **Same code embedded 3x** — pi-monitor.service, uninstall.sh, requirements.txt are embedded in install.sh AND written again in setup.sh | Divergent copies, one gets updated, other doesn't |
| C3 | **set -e on massive scripts** — 1400+ lines with `set -e` means any unexpected failure in any subshell/pipe aborts the entire script with no cleanup | Fragile, hard to debug (which line failed?) |
| C4 | **Security: API tokens in process args** — `--iotpush-key`, `--api-token`, `--tailscale-key` passed as CLI args (visible in `ps aux`) | Credential exposure on multi-user systems |
| C5 | **VNC listens on all interfaces** — `localhost=no` in VNC config, no firewall rule, just "Tailscale provides security" | VNC exposed to LAN even without Tailscale |

### Structural

| # | Issue | Impact |
|---|-------|--------|
| S1 | **God functions** — `do_iotpush()` is 180 lines, `_install_remote_desktop()` is 160 lines, `do_install()` is 200+ lines | Hard to read, test, or modify |
| S2 | **No error handling pattern** — Mix of `|| true`, `2>/dev/null`, unchecked returns, `set -e` | Inconsistent, bugs silently swallowed |
| S3 | **No state validation** — setup.sh reads .env with grep+cut but never validates the values are sane | Garbage in, garbage out |
| S4 | **No idempotency** — Running install twice creates duplicate systemd reloads, may overwrite configs unpredictably | Can't re-run safely |
| S5 | **Two config files (.env + settings.json) with overlapping keys** — iotpush keys in both, tailscale_only in both, different formats | Confusing, can get out of sync |
| S6 | **QR code generation duplicated 3 times** — Post-install, do_qrcode, and install.sh all have nearly identical QR generation code | Copy-paste drift |
| S7 | **No logging** — setup.sh has no log file, errors go to terminal only | Can't debug after the fact |
| S8 | **gum_input helper hides errors** — Wraps gum input with no validation that gum actually succeeded | Silent failures |

### Design Debt

| # | Issue | Impact |
|---|-------|--------|
| D1 | **Pi vs VPS is really Tailscale vs no-Tailscale** — The only difference is whether Tailscale is used. The device type label is cosmetic but leaks into QR codes, config, and UI | Confusing model, should just be "Tailscale on/off" |
| D2 | **VNC install in setup agent script** — Remote desktop is orthogonal to zero-trust monitoring | Scope creep, should be separate module/plugin |
| D3 | **AI page generation baked into monitoring agent** — Anthropic API integration, HTML page management, Tailscale Funnel control are all in the core agent | Agent does too many things |
| D4 | **Update mechanism is fragile** — Tries git pull first, then falls back to curl-pipe. The curl-pipe re-runs the entire embedded heredoc. No version pinning. | Updates can break things |
| D5 | **ExecStartPre runs pip install on every start** — The systemd service runs `pip install -q -r requirements.txt` on every boot | Slow boot, potential network-dependent startup failure |

### Code Quality

| # | Issue | Impact |
|---|-------|--------|
| Q1 | **Mixed styling** — Some functions use `echo -e "${GREEN}..."`, others use `gum style`, others use both | Inconsistent UI |
| Q2 | **Hardcoded URLs** — `https://www.iotpush.com/api/push/`, `https://install.dasecure.com`, GitHub raw URLs scattered everywhere | Can't change endpoints without find-replace |
| Q3 | **vncpasswd called incorrectly** — `echo "$VNC_PASS\nn" | vncpasswd` doesn't work as intended (echo doesn't interpret \n without -e) | View-only password not actually being set |
| Q4 | **Version in 3 places** — AGENT_VERSION in pi-monitor.py, "v3.0" in comments, "3.0.0" in FastAPI | Which is canonical? |
| Q5 | **Uninstall removes wrong service file** — `rm -f /etc/systemd/system/vncserver@.service` (with @) but installs `vncserver.service` (without @) | Uninstall doesn't clean up the actual service file |

---

## 3. Proposed Rewrite Architecture

### Principles

1. **One file = one concern** — Separate the agent Python code from shell scripts
2. **No more heredoc embedding** — pi-monitor.py lives as a real file, installed via copy or git
3. **Module-based TUI** — Each menu item is its own file, sourced by a thin main loop
4. **Idempotent everywhere** — Safe to re-run any operation
5. **Proper error handling** — trap ERR, log to file, show actionable messages

### Proposed Structure

```
pi-install/
├── setup.sh                    # Thin TUI entry point (~200 lines)
│                               #   - ensure_gum, main menu loop, source modules
│
├── install.sh                  # Headless installer (~300 lines)
│                               #   - Still curl-pipeable
│                               #   - Copies files from lib/ instead of heredoc
│
├── lib/                        # Shared shell functions
│   ├── common.sh               #   Colors, logging, error handling, gum helpers
│   ├── config.sh               #   .env + settings.json read/write/validate
│   ├── agent.sh                #   Install/update/uninstall pi-monitor service
│   ├── tailscale.sh            #   Tailscale install/connect/disconnect
│   ├── iotpush.sh              #   iotPush configure/test/disable
│   ├── vnc.sh                  #   Remote desktop install/configure/remove
│   └── qrcode.sh               #   QR generation (single implementation)
│
├── agent/                      # Pi-monitor Python app (REAL FILES, not heredoc)
│   ├── pi_monitor/
│   │   ├── __init__.py
│   │   ├── main.py             #   FastAPI app + lifespan
│   │   ├── config.py           #   Settings, env loading
│   │   ├── auth.py             #   Token + Tailscale auth
│   │   ├── routes/
│   │   │   ├── system.py       #   /health, /stats, /system
│   │   │   ├── logs.py         #   /logs, /logs/stream
│   │   │   ├── settings.py     #   /settings CRUD
│   │   │   ├── notify.py       #   /notify, iotPush integration
│   │   │   ├── pages.py        #   /pages, /ai/generate, /funnel
│   │   │   └── control.py      #   /reboot, /shutdown, /update
│   │   └── utils.py            #   tailscale, hardware, formatting helpers
│   ├── requirements.txt
│   └── pi-monitor.service      #   systemd unit
│
├── uninstall.sh
└── README.md
```

### Key Changes

1. **Agent as real Python package** — Can be linted, tested, developed normally. Install copies from `agent/` to `/opt/pi-utility/pi-service/`.

2. **Sourced modules instead of god functions** — `setup.sh` is ~200 lines: ensure_gum, menu loop, `source lib/*.sh` on boot, dispatch to `do_*` functions from modules.

3. **Single config source** — .env only. settings.json is generated FROM .env, never the other way. Or switch to a single YAML/TOML config.

4. **Device type = just a label** — Tailscale on/off is the real toggle. Device type (Pi/VPS) is auto-detected or cosmetic, doesn't affect config structure.

5. **Error handling pattern:**
   ```bash
   set -uo pipefail  # no -e
   trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
   LOG_FILE="/var/log/pi-setup.log"
   log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }
   ```

6. **No pip on every boot** — pip install only during install/update. Systemd just starts uvicorn.

7. **VNC as opt-in module** — Not in the core flow. Separate menu item, separate lib file, clearly scoped.

8. **Version in exactly one place** — `agent/pi_monitor/__init__.py` has `__version__`. Everything else reads from there.

### Migration Path

1. Extract pi-monitor.py from heredoc → real files in `agent/`
2. Extract shared functions into `lib/` modules
3. Thin out setup.sh to just menu + source
4. Test that both curl-pipe and local install still work
5. Update install.sh to `cp -r agent/ /opt/pi-utility/pi-service/`

---

## 4. Quick Wins (fix before rewrite)

These can be fixed in the current code now:

- [ ] Fix vncpasswd call (`echo -e` or use printf)
- [ ] Fix uninstall service filename (`vncserver@.service` → `vncserver.service`)
- [ ] Remove `ExecStartPre=pip install` from systemd unit
- [ ] Consolidate version to one location
- [ ] Add `set -uo pipefail` + ERR trap instead of `set -e`
- [ ] Move API tokens to env vars or temp files instead of CLI args
- [ ] Deduplicate QR code generation into one function
- [ ] Add LOG_FILE and log() function
