# Pi Zero-Trust Agent

A modern, cross-platform monitoring agent with an interactive TUI installer.

## Quick Install (one-liner)

```bash
curl -fsSL https://raw.githubusercontent.com/dasecure/pi-install/main/start.sh | sudo bash
```

This will:
1. Install Go (if not present)
2. Download the source
3. Build `pi-agent` and launch the interactive TUI

## Pre-built Binaries

Download from [Releases](https://github.com/dasecure/pi-install/releases):

| Platform | Arch | Binary |
|----------|------|--------|
| Linux | arm64 | `pi-agent` (for Raspberry Pi) |
| Linux | amd64 | `pi-agent` (for VPS) |
| macOS | arm64 | `pi-agent` |
| macOS | amd64 | `pi-agent` |
| Windows | amd64 | `pi-agent.exe` |

## Usage

```bash
pi-agent              # Interactive TUI setup
pi-agent serve        # Start monitoring agent (HTTP API on :8080)
pi-agent install      # Headless install (for scripting)
pi-agent version      # Print version
```

### Headless Install (VPS)

```bash
pi-agent install \
  --no-tailscale \
  --hostname my-vps \
  --iotpush-key YOUR_KEY \
  --iotpush-topic YOUR_TOPIC
```

### Headless Install (Pi with Tailscale)

```bash
pi-agent install \
  --tailscale-key tskey-auth-xxx \
  --hostname my-pi \
  --iotpush-key YOUR_KEY \
  --iotpush-topic YOUR_TOPIC
```

## API Endpoints

| Endpoint | Auth | Description |
|----------|------|-------------|
| `GET /health` | No | Health check |
| `GET /stats` | Yes | System stats (CPU, RAM, disk, temp) |
| `GET /system` | Yes | Platform info, Tailscale, Pi model |
| `GET /logs/{type}` | Yes | System logs (journalctl) |
| `GET /settings` | Yes | Current config |
| `PUT /settings` | Yes | Update config |
| `POST /notify` | Yes | Send push notification |
| `POST /reboot` | Yes | Reboot device |
| `POST /shutdown` | Yes | Shutdown device |

Auth: `X-API-Token` header or `Authorization: Bearer <token>`. Tailscale IPs (100.x.x.x) are auto-trusted.

## Build from Source

```bash
go build -ldflags "-s -w" -o pi-agent .
make all    # cross-compile all platforms
```

## Architecture

```
pi-agent (single binary)
├── TUI mode (default)       — Bubble Tea interactive setup wizard
├── serve                    — HTTP monitoring agent (replaces Python)
├── install                  — Headless multi-stage pipeline
└── config: /etc/pi-zero-trust/config.yaml
```

## Requirements

- Linux (Debian/Ubuntu recommended), macOS, or Windows
- For Tailscale features: [Tailscale](https://tailscale.com) installed
- For iotPush notifications: [iotPush](https://iotpush.com) account
