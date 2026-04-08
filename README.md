# Pi Zero-Trust Agent Installer

Self-contained install script for the [Pi Zero-Trust](https://github.com/dasecure/pi-zero-trust) agent. Sets up the monitoring agent on any Linux machine — no git clone needed, all files are embedded in the script.

## Install on Pi (with Tailscale)

```bash
curl -fsSL https://raw.githubusercontent.com/dasecure/pi-install/main/install.sh | sudo bash -s -- \
  --iotpush-key YOUR_KEY \
  --iotpush-topic YOUR_TOPIC \
  --tailscale-key tskey-auth-XXXXX \
  --hostname my-pi
```

## Install on VPS (without Tailscale)

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

From the PiControl app: tap **Update Agent** on the Dashboard.

Or manually on the device:

```bash
curl -fsSL https://raw.githubusercontent.com/dasecure/pi-install/main/install.sh | sudo bash -s -- --update
sudo systemctl restart pi-monitor
```

## Uninstall Agent

From the PiControl app: tap **Uninstall Agent** on the Dashboard.

Or manually on the device:

```bash
sudo bash /opt/pi-utility/uninstall.sh
```

This removes the agent service, files, and config. Tailscale is left installed.

## Options

| Flag | Description |
|------|-------------|
| `--hostname NAME` | Set the device hostname |
| `--tailscale-key KEY` | Tailscale auth key for automatic join |
| `--iotpush-key KEY` | iotPush API key for push notifications |
| `--iotpush-topic TOPIC` | iotPush topic for notifications |
| `--no-tailscale` | Skip Tailscale setup (for VPS installs) |
| `--api-token TOKEN` | Set a custom API token (auto-generated if omitted) |
| `--update` | Update agent files only (skip config/Tailscale) |

## Get Your Keys

- **iotPush**: [iotpush.com/settings](https://iotpush.com/settings)
- **Tailscale**: [login.tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys)

## License

MIT - DaSecure Solutions LLC
