# Pi Zero-Trust Agent Installer

Self-contained install script for the [Pi Zero-Trust](https://github.com/dasecure/pi-zero-trust) agent. Sets up the monitoring agent on any Linux machine — no git clone needed, all files are embedded in the script.

## Quick Start (Interactive TUI)

The easiest way to get started. A guided terminal UI walks you through everything — no CLI flags needed:

```bash
curl -fsSL https://raw.githubusercontent.com/dasecure/pi-install/main/setup.sh | sudo bash
```

The TUI will guide you through:

1. **Device type** — Raspberry Pi (with Tailscale) or VPS (no Tailscale)
2. **Hostname** — set your device name
3. **iotPush** — enter your API key and topic for push notifications (validated live against the API)
4. **Tailscale** — enter your auth key (Pi mode only)
5. **API token** — custom or auto-generated
6. **Confirmation** — review all settings before installing

After install, you get:
- 🩺 Health check against the agent
- 📱 QR code for PiControl app
- 🔔 Optional test push notification
- ✅ Service status verification

### TUI Menu Options

Once installed, the TUI provides a full management menu:

| Option | Description |
|--------|-------------|
| 📊 **Status** | Service health, IP, API endpoint, live logs |
| 🔔 **iotPush** | Configure, test, update, or disable push notifications |
| 🔄 **Update Agent** | One-click update with live logs |
| 🗑 **Uninstall Agent** | Double-confirmed removal |
| 🚀 **Install Agent** | Shown when agent is not yet installed |

### iotPush Management

The dedicated iotPush menu lets you:

- **Test Push** — send a notification to verify credentials are working
- **Update Credentials** — change your API key or topic (validated against the API)
- **Disable** — remove credentials and turn off notifications
- **Set Up** — configure iotPush for the first time

Push notifications are sent via `POST /api/push/{topic}` on [iotpush.com](https://iotpush.com). Get your key at [iotpush.com/settings](https://iotpush.com/settings).

---

## CLI Install (Advanced)

If you prefer the command line or need to automate installs:

### Install on Pi (with Tailscale)

```bash
curl -fsSL https://raw.githubusercontent.com/dasecure/pi-install/main/install.sh | sudo bash -s -- \
  --iotpush-key YOUR_KEY \
  --iotpush-topic YOUR_TOPIC \
  --tailscale-key tskey-auth-XXXXX \
  --hostname my-pi
```

### Install on VPS (without Tailscale)

```bash
curl -fsSL https://raw.githubusercontent.com/dasecure/pi-install/main/install.sh | sudo bash -s -- \
  --no-tailscale \
  --hostname my-vps
```

An API token is auto-generated and printed at the end. You can also provide your own:

```bash
curl -fsSL https://raw.githubusercontent.com/dasecure/pi-install/main/install.sh | sudo bash -s -- \
  --no-tailscale \
  --hostname my-vps \
  --api-token YOUR_TOKEN
```

After install, a QR code is displayed in the terminal. Scan it in the PiControl iOS app (Settings > Scan QR) to add the device instantly.

## Update Agent

**Interactive:** Run the TUI and choose "Update Agent":
```bash
sudo bash /opt/pi-utility/setup.sh  # or curl the setup.sh again
```

**CLI:**
```bash
curl -fsSL https://raw.githubusercontent.com/dasecure/pi-install/main/install.sh | sudo bash -s -- --update
sudo systemctl restart pi-monitor
```

**PiControl app:** Tap **Update Agent** on the Dashboard.

## Uninstall Agent

**Interactive:** Run the TUI and choose "Uninstall Agent":
```bash
sudo bash /opt/pi-utility/setup.sh  # or curl the setup.sh again
```

**CLI:**
```bash
sudo bash /opt/pi-utility/uninstall.sh
```

**PiControl app:** Tap **Uninstall Agent** on the Dashboard.

This removes the agent service, files, and config. Tailscale is left installed.

## CLI Options

| Flag | Description |
|------|-------------|
| `--hostname NAME` | Set the device hostname |
| `--tailscale-key KEY` | Tailscale auth key for automatic join |
| `--iotpush-key KEY` | iotPush API key for push notifications |
| `--iotpush-topic TOPIC` | iotPush topic for notifications |
| `--no-tailscale` | Skip Tailscale setup (for VPS installs) |
| `--api-token TOKEN` | Set a custom API token (auto-generated if omitted) |
| `--watchdog` | Enable hardware watchdog (Pi only) |
| `--update` | Update agent files only (skip config/Tailscale) |

## Get Your Keys

- **iotPush**: [iotpush.com/settings](https://iotpush.com/settings)
- **Tailscale**: [login.tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys)

## License

MIT - DaSecure Solutions LLC
