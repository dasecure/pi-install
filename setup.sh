#!/bin/bash
# Pi Zero-Trust Agent v3.0 - Interactive TUI Setup
# Uses gum for beautiful terminal prompts
# Usage: curl -fsSL https://raw.githubusercontent.com/dasecure/pi-install/main/setup.sh | sudo bash
#   or:  sudo bash setup.sh

set -e

# ──────────────────────────────────────────────
# Colors & Constants
# ──────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

GUM_VERSION="0.14.3"
INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/dasecure/pi-install/main/install.sh"

# ──────────────────────────────────────────────
# Dependency check / install
# ──────────────────────────────────────────────
ensure_gum() {
    if command -v gum &>/dev/null; then
        return 0
    fi

    echo -e "${YELLOW}gum not found — installing...${NC}"

    # Detect arch
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  GUM_ARCH="x86_64" ;;
        aarch64|arm64) GUM_ARCH="arm64" ;;
        armv7l)  GUM_ARCH="armv7" ;;
        armv6l)  GUM_ARCH="armhf" ;;
        *)       echo -e "${RED}Unsupported architecture: $ARCH${NC}"; exit 1 ;;
    esac

    GUM_TARBALL="gum_${GUM_VERSION}_linux_${GUM_ARCH}.tar.gz"
    GUM_URL="https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/${GUM_TARBALL}"

    TMPDIR=$(mktemp -d)
    trap 'rm -rf "$TMPDIR"' EXIT

    curl -fsSL "$GUM_URL" | tar xz -C "$TMPDIR"

    # The tarball extracts into a directory like gum_0.14.3_linux_arm64/
    GUM_BIN=$(find "$TMPDIR" -name gum -type f | head -1)
    if [ -z "$GUM_BIN" ]; then
        echo -e "${RED}Could not find gum binary in archive${NC}"
        exit 1
    fi

    cp "$GUM_BIN" /usr/local/bin/gum
    chmod +x /usr/local/bin/gum
    echo -e "${GREEN}✓ gum installed${NC}"
}

# ──────────────────────────────────────────────
# Helper: styled gum input with default
# ──────────────────────────────────────────────
gum_input() {
    local prompt="$1"
    local default="${2:-}"
    local flags="${3:-}"

    if [ -n "$default" ]; then
        gum input --prompt "$prompt" --value "$default" $flags
    else
        gum input --prompt "$prompt" $flags
    fi
}

# ──────────────────────────────────────────────
# Banners
# ──────────────────────────────────────────────
show_banner() {
    gum style \
        --border double \
        --border-foreground 36 \
        --margin "1 2" \
        --padding "1 4" \
        "$(gum style --bold --foreground 36 '🔒 Pi Zero-Trust Agent')"
    echo ""
    gum style --faint "  Interactive Setup — no CLI flags needed"
    echo ""
}

show_success_banner() {
    local device_type="$1"
    local hostname="$2"
    local ip="$3"
    local token="$4"
    local tailscale_only="$5"

    echo ""
    gum style \
        --border double \
        --border-foreground 76 \
        --margin "1 2" \
        --padding "1 4" \
        "$(gum style --bold --foreground 76 '✅ Setup Complete!')"
    echo ""
    gum style --bold "  Device Details"
    echo -e "  ─────────────────────────────────────"
    echo -e "  Type:       $(gum style --foreground 76 "$device_type")"
    echo -e "  Hostname:   $(gum style --foreground 76 "$hostname")"
    if [ "$tailscale_only" = "true" ]; then
        echo -e "  Tailscale:  $(gum style --foreground 76 "$ip")"
    fi
    echo -e "  API:        $(gum style --foreground 76 "http://$ip:8080")"
    echo -e "  Token:      $(gum style --foreground 214 "$token")"
    echo ""
    echo -e "  $(gum style --faint 'Test: curl http://'$ip':8080/health')"
    echo ""
}

# ──────────────────────────────────────────────
# Menu actions
# ──────────────────────────────────────────────
do_install() {
    clear
    show_banner

    # ── Step 1: Mode selection ──
    gum style --bold --foreground 36 "  Step 1: Choose your device type"
    echo ""

    MODE=$(gum choose \
        --cursor="▸ " \
        --cursor.foreground 36 \
        --selected.foreground 36 \
        --header "" \
        "Raspberry Pi (with Tailscale)" \
        "VPS / Server (no Tailscale)")

    if [ -z "$MODE" ]; then
        echo -e "${RED}Cancelled.${NC}"
        exit 0
    fi

    if [[ "$MODE" == *"VPS"* ]]; then
        NO_TAILSCALE=true
        DEVICE_TYPE="VPS"
    else
        NO_TAILSCALE=false
        DEVICE_TYPE="Pi"
    fi

    echo ""
    gum style --faint "  Selected: $MODE"
    echo ""

    # ── Step 2: Hostname ──
    gum style --bold --foreground 36 "  Step 2: Set hostname"
    echo ""
    CURRENT_HOSTNAME=$(hostname 2>/dev/null || echo "zerotrust-pi")
    HOSTNAME_VAL=$(gum_input "  Hostname [$CURRENT_HOSTNAME]: " "")
    HOSTNAME_VAL="${HOSTNAME_VAL:-$CURRENT_HOSTNAME}"
    echo ""

    # ── Step 3: API keys ──
    IOTPUSH_KEY=""
    IOTPUSH_TOPIC=""
    TAILSCALE_KEY=""
    API_TOKEN=""

    gum style --bold --foreground 36 "  Step 3: Configure API keys"
    echo ""

    # iotPush
    gum style "  $(gum style --bold 'iotPush') — push notifications"
    echo "  $(gum style --faint 'Get your key: https://iotpush.com/settings')"
    echo ""

    gum confirm "  Configure iotPush?" && {
        IOTPUSH_KEY=$(gum_input "  iotPush API Key: " "" "--password")
        IOTPUSH_TOPIC=$(gum_input "  iotPush Topic (e.g. my-alerts): " "")

        # Validate credentials against API
        if [ -n "$IOTPUSH_KEY" ] && [ -n "$IOTPUSH_TOPIC" ]; then
            echo ""
            echo -e "  ${DIM}Verifying iotPush credentials...${NC}"
            TEST_RESP=$(curl -sfL --connect-timeout 5 \
                -H "Authorization: Bearer $IOTPUSH_KEY" \
                -H "Content-Type: application/json" \
                -d '{"title":"Pi Setup Test","message":"iotPush credentials verified during setup"}' \
                "https://iotpush.com/api/push/$IOTPUSH_TOPIC" 2>/dev/null) && {
                echo -e "  $(gum style --foreground 76 '✓ iotPush credentials valid — test push sent')"
            } || {
                echo -e "  $(gum style --foreground 214 '⚠ Could not verify — check your key and topic')"
                gum confirm "  Continue anyway?" || {
                    IOTPUSH_KEY=""
                    IOTPUSH_TOPIC=""
                }
            }
        fi
    } || true
    echo ""

    # Tailscale (Pi mode only)
    if [ "$NO_TAILSCALE" = false ]; then
        gum style "  $(gum style --bold 'Tailscale') — secure mesh VPN"
        echo "  $(gum style --faint 'Get your key: https://login.tailscale.com/admin/settings/keys')"
        echo ""

        TAILSCALE_KEY=$(gum_input "  Tailscale Auth Key: " "" "--password")

        if [ -z "$TAILSCALE_KEY" ]; then
            echo -e "  ${RED}Tailscale key is required for Pi mode.${NC}"
            gum confirm "  Continue without Tailscale? (switches to VPS mode)" && {
                NO_TAILSCALE=true
                DEVICE_TYPE="VPS"
            } || exit 1
        fi
        echo ""
    fi

    # ── Step 4: API Token ──
    gum style --bold --foreground 36 "  Step 4: API Token"
    echo ""

    CUSTOM_TOKEN=$(gum confirm "  Use a custom API token?" && echo "yes" || echo "no")

    if [ "$CUSTOM_TOKEN" = "yes" ]; then
        API_TOKEN=$(gum_input "  API Token: " "")
    fi
    echo ""

    # ── Step 5: Watchdog ──
    WATCHDOG_FLAG=""
    if [ "$NO_TAILSCALE" = false ]; then
        gum style --bold --foreground 36 "  Step 5: Watchdog"
        echo ""
        gum confirm "  Enable hardware watchdog?" && WATCHDOG_FLAG="--watchdog"
        echo ""
    fi

    # ── Confirmation ──
    clear
    gum style --bold --foreground 214 "  ⚡  Ready to install — confirm your settings:"
    echo ""
    echo -e "  Mode:        $(gum style --foreground 76 "$DEVICE_TYPE")"
    echo -e "  Hostname:    $(gum style --foreground 76 "$HOSTNAME_VAL")"
    if [ -n "$IOTPUSH_KEY" ]; then
        echo -e "  iotPush:     $(gum style --foreground 76 'configured')"
    else
        echo -e "  iotPush:     $(gum style --faint 'skipped')"
    fi
    if [ "$NO_TAILSCALE" = false ]; then
        echo -e "  Tailscale:   $(gum style --foreground 76 'enabled')"
    else
        echo -e "  Tailscale:   $(gum style --faint 'disabled')"
    fi
    if [ -n "$WATCHDOG_FLAG" ]; then
        echo -e "  Watchdog:    $(gum style --foreground 76 'enabled')"
    fi
    if [ -n "$API_TOKEN" ]; then
        echo -e "  API Token:   $(gum style --foreground 214 'custom')"
    else
        echo -e "  API Token:   $(gum style --faint 'auto-generated')"
    fi
    echo ""

    gum confirm "  Install with these settings?" || {
        echo -e "${YELLOW}Cancelled.${NC}"
        exit 0
    }

    # ── Build and run install command ──
    echo ""
    echo -e "${GREEN}Starting installation...${NC}"
    echo ""

    INSTALL_ARGS=""

    if [ "$NO_TAILSCALE" = true ]; then
        INSTALL_ARGS="$INSTALL_ARGS --no-tailscale"
    fi

    INSTALL_ARGS="$INSTALL_ARGS --hostname $HOSTNAME_VAL"

    if [ -n "$IOTPUSH_KEY" ] && [ -n "$IOTPUSH_TOPIC" ]; then
        INSTALL_ARGS="$INSTALL_ARGS --iotpush-key $IOTPUSH_KEY --iotpush-topic $IOTPUSH_TOPIC"
    fi

    if [ "$NO_TAILSCALE" = false ] && [ -n "$TAILSCALE_KEY" ]; then
        INSTALL_ARGS="$INSTALL_ARGS --tailscale-key $TAILSCALE_KEY"
    fi

    if [ -n "$API_TOKEN" ]; then
        INSTALL_ARGS="$INSTALL_ARGS --api-token $API_TOKEN"
    fi

    if [ -n "$WATCHDOG_FLAG" ]; then
        INSTALL_ARGS="$INSTALL_ARGS $WATCHDOG_FLAG"
    fi

    # Run the installer — prefer local install.sh, fall back to curl
    if [ -f "$(dirname "$0")/install.sh" ]; then
        bash "$(dirname "$0")/install.sh" $INSTALL_ARGS
    else
        curl -fsSL "$INSTALL_SCRIPT_URL" | bash -s -- $INSTALL_ARGS
    fi

    INSTALL_EXIT=$?
    if [ $INSTALL_EXIT -ne 0 ]; then
        echo ""
        echo -e "${RED}Installation failed (exit code $INSTALL_EXIT).${NC}"
        echo -e "${DIM}Check logs: journalctl -u pi-monitor -n 50${NC}"
        exit $INSTALL_EXIT
    fi

    # ── Post-install ──
    do_post_install
}

do_post_install() {
    echo ""
    gum style --bold --foreground 36 "  🎉 Post-Install"
    echo ""

    # Read back the installed config
    if [ -f /etc/pi-zero-trust/.env ]; then
        # Extract token for display
        INSTALLED_TOKEN=$(grep '^PI_API_TOKEN=' /etc/pi-zero-trust/.env 2>/dev/null | cut -d= -f2 || echo "")
        INSTALLED_HOSTNAME=$(grep '^HOSTNAME=' /etc/pi-zero-trust/.env 2>/dev/null | cut -d= -f2 || echo "$HOSTNAME_VAL")

        # Get the IP
        if command -v tailscale &>/dev/null; then
            INSTALLED_IP=$(tailscale ip -4 2>/dev/null || hostname -I | awk '{print $1}')
        else
            INSTALLED_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")
        fi

        # Determine type
        TAILSCALE_ONLY=$(grep '^TAILSCALE_ONLY=' /etc/pi-zero-trust/.env 2>/dev/null | cut -d= -f2 || echo "false")

        show_success_banner \
            "$( [ "$TAILSCALE_ONLY" = "true" ] && echo 'Pi' || echo 'VPS' )" \
            "${INSTALLED_HOSTNAME:-$HOSTNAME_VAL}" \
            "$INSTALLED_IP" \
            "$INSTALLED_TOKEN" \
            "$TAILSCALE_ONLY"
    fi

    # Test health endpoint
    gum style --bold "  Health Check"
    echo ""

    TEST_IP="${INSTALLED_IP:-$(hostname -I | awk '{print $1}')}"
    HEALTH_RESULT=$(curl -sfL --connect-timeout 5 "http://${TEST_IP}:8080/health" 2>/dev/null) && {
        echo -e "  $(gum style --foreground 76 '✓ Agent is healthy')"
        echo -e "  $(gum style --faint "$HEALTH_RESULT")"
    } || {
        echo -e "  $(gum style --foreground 214 '⚠ Agent not responding yet — may need a moment')"
        echo -e "  $(gum style --faint "Retry: curl http://${TEST_IP}:8080/health")"
    }
    echo ""

    # Test notification (if iotPush configured)
    if [ -f /etc/pi-zero-trust/.env ]; then
        IOTPUSH_KEY_VAL=$(grep '^IOTPUSH_API_KEY=' /etc/pi-zero-trust/.env 2>/dev/null | cut -d= -f2)
        IOTPUSH_TOPIC_VAL=$(grep '^IOTPUSH_TOPIC=' /etc/pi-zero-trust/.env 2>/dev/null | cut -d= -f2)
        if [ -n "$IOTPUSH_KEY_VAL" ] && [ -n "$IOTPUSH_TOPIC_VAL" ]; then
            gum confirm "  Send a test push notification?" && {
                echo ""
                HOSTNAME_DISPLAY="${INSTALLED_HOSTNAME:-$(hostname)}"
                TEST_RESP=$(curl -sfL --connect-timeout 5 \
                    -H "Authorization: Bearer $IOTPUSH_KEY_VAL" \
                    -H "Content-Type: application/json" \
                    -d "{\"title\":\"🧪 Test from $HOSTNAME_DISPLAY\",\"message\":\"iotPush is working! Sent during Pi Zero-Trust setup.\",\"priority\":\"normal\"}" \
                    "https://iotpush.com/api/push/$IOTPUSH_TOPIC_VAL" 2>/dev/null) && {
                    echo -e "  $(gum style --foreground 76 '✓ Test notification sent')"
                    if [ -n "$TEST_RESP" ]; then
                        echo -e "  $(gum style --faint "$TEST_RESP")"
                    fi
                } || {
                    echo -e "  $(gum style --foreground 214 '⚠ Could not send test notification')"
                }
            }
            echo ""
        fi
    fi

    # Show QR code
    if command -v /opt/pi-utility/venv/bin/python3 &>/dev/null; then
        QR_DATA="{\"h\":\"${INSTALLED_HOSTNAME:-$HOSTNAME_VAL}\",\"a\":\"${INSTALLED_IP}\",\"p\":8080,\"t\":\"${INSTALLED_TOKEN}\",\"d\":\"$( [ "$TAILSCALE_ONLY" = "true" ] && echo 'pi' || echo 'vps')\"}"
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
            echo -e "  $(gum style --foreground 36 '📱 Scan this QR in PiControl app → Settings → Scan QR')"
            echo ""
        } || true
    fi

    # Service status
    gum style --bold "  Service Status"
    echo ""
    if systemctl is-active --quiet pi-monitor 2>/dev/null; then
        echo -e "  $(gum style --foreground 76 '● pi-monitor is running')"
    else
        echo -e "  $(gum style --foreground 214 '● pi-monitor is not running')"
        echo -e "  $(gum style --faint '  Start: sudo systemctl start pi-monitor')"
        echo -e "  $(gum style --faint '  Logs:  journalctl -u pi-monitor -f')"
    fi
    echo ""

    gum style --faint "  Useful commands:"
    echo -e "  $(gum style --faint 'View logs:  ')journalctl -u pi-monitor -f"
    echo -e "  $(gum style --faint 'Restart:    ')sudo systemctl restart pi-monitor"
    echo -e "  $(gum style --faint 'Uninstall:  ')sudo bash $(dirname "$0")/setup.sh  # → choose Uninstall"
    echo -e "  $(gum style --faint 'Status:     ')curl http://${INSTALLED_IP}:8080/health"
    echo ""

    gum style --bold --foreground 36 "  Done! 🖖"
    echo ""
}

do_update() {
    clear
    show_banner

    gum style --bold --foreground 36 "  🔄 Update Agent"
    echo ""

    # Check current version
    if systemctl is-active --quiet pi-monitor 2>/dev/null; then
        CURRENT_VER=$(/opt/pi-utility/venv/bin/python3 -c "
import sys; sys.path.insert(0,'/opt/pi-utility/pi-service')
try:
    exec(open('/opt/pi-utility/pi-service/pi-monitor.py').read().split('AGENT_VERSION')[1].split('=')[1].split('\n')[0].strip().strip('\"').strip(\"'\"))
except: pass
" 2>/dev/null || echo "unknown")
        echo -e "  Current version: $(gum style --foreground 76 "$CURRENT_VER")"
    else
        echo -e "  $(gum style --foreground 214 '⚠ Agent service is not running')"
    fi
    echo ""

    gum confirm "  Download and apply update?" || {
        echo -e "${YELLOW}Cancelled.${NC}"
        return
    }
    echo ""

    echo -e "${GREEN}Updating agent files...${NC}"
    echo ""

    # Prefer local, fall back to curl
    if [ -f "$(dirname "$0")/install.sh" ]; then
        bash "$(dirname "$0")/install.sh" --update
    else
        curl -fsSL "$INSTALL_SCRIPT_URL" | bash -s -- --update
    fi

    echo ""
    echo -e "${GREEN}Restarting agent...${NC}"
    systemctl restart pi-monitor
    sleep 2

    if systemctl is-active --quiet pi-monitor; then
        echo -e "  $(gum style --foreground 76 '✓ Agent updated and running')"
    else
        echo -e "  $(gum style --foreground 214 '⚠ Agent may need a moment — check: journalctl -u pi-monitor -n 20')"
    fi
    echo ""
    gum confirm "  View live logs?" && {
        echo ""
        journalctl -u pi-monitor -f --no-pager -n 20
    }
}

do_uninstall() {
    clear
    show_banner

    gum style --bold --foreground 214 "  🗑  Uninstall Agent"
    echo ""

    # Show what will be removed
    gum style "  The following will be removed:"
    echo ""
    echo -e "    $(gum style --foreground 214 '•') pi-monitor service (stopped + disabled)"
    echo -e "    $(gum style --foreground 214 '•') /opt/pi-utility/ (agent files)"
    echo -e "    $(gum style --foreground 214 '•') /etc/pi-zero-trust/ (config)"
    echo -e "    $(gum style --foreground 214 '•') /var/log/pi-monitor/ (logs)"
    echo -e "    $(gum style --foreground 214 '•') /var/www/pi-pages/ (pages)"
    echo -e "    $(gum style --foreground 214 '•') /usr/local/bin/pi-notify"
    echo ""
    echo -e "  $(gum style --faint 'Tailscale will NOT be removed.')"
    echo ""

    gum confirm --default=false "  Are you sure you want to uninstall?" || {
        echo -e "${YELLOW}Cancelled.${NC}"
        return
    }
    echo ""

    # Second confirmation for safety
    gum confirm --default=false "  Really? This cannot be undone." || {
        echo -e "${YELLOW}Cancelled.${NC}"
        return
    }
    echo ""

    echo -e "${YELLOW}Uninstalling...${NC}"
    echo ""

    if [ -x /opt/pi-utility/uninstall.sh ]; then
        bash /opt/pi-utility/uninstall.sh
    else
        # Inline uninstall if script missing
        systemctl stop pi-monitor 2>/dev/null || true
        systemctl disable pi-monitor 2>/dev/null || true
        rm -f /etc/systemd/system/pi-monitor.service
        systemctl daemon-reload
        rm -rf /opt/pi-utility
        rm -rf /etc/pi-zero-trust
        rm -rf /var/log/pi-monitor
        rm -rf /var/www/pi-pages
        rm -f /usr/local/bin/pi-notify

        echo -e "  ${GREEN}✓${NC} All agent files removed"
    fi

    echo ""
    gum style \
        --border double \
        --border-foreground 214 \
        --margin "1 2" \
        --padding "1 4" \
        "$(gum style --bold --foreground 214 '🗑  Agent Uninstalled')"
    echo ""
    echo -e "  Tailscale was $(gum style --bold 'not') removed."
    echo -e "  $(gum style --faint 'To remove Tailscale: sudo tailscale logout && sudo apt remove tailscale')"
    echo ""
}

do_iotpush() {
    clear
    show_banner

    gum style --bold --foreground 36 "  🔔 iotPush Configuration"
    echo ""
    gum style --faint "  Push notifications via iotpush.com/api/push/{topic}"
    echo ""

    ENV_FILE="/etc/pi-zero-trust/.env"
    SETTINGS_FILE="/etc/pi-zero-trust/settings.json"

    CURRENT_KEY=""
    CURRENT_TOPIC=""
    if [ -f "$ENV_FILE" ]; then
        CURRENT_KEY=$(grep '^IOTPUSH_API_KEY=' "$ENV_FILE" 2>/dev/null | cut -d= -f2)
        CURRENT_TOPIC=$(grep '^IOTPUSH_TOPIC=' "$ENV_FILE" 2>/dev/null | cut -d= -f2)
    fi

    if [ -n "$CURRENT_KEY" ] && [ -n "$CURRENT_TOPIC" ]; then
        gum style "  Current configuration:"
        echo -e "    Topic:    $(gum style --foreground 76 "$CURRENT_TOPIC")"
        echo -e "    API Key:  $(gum style --foreground 76 "${CURRENT_KEY:0:8}...")"
        echo ""

        ACTION=$(gum choose \
            --cursor="▸ " \
            --cursor.foreground 36 \
            --selected.foreground 36 \
            "🧪  Test Push" \
            "✏️   Update Credentials" \
            "🔌  Disable iotPush" \
            "↩   Back")
    else
        echo -e "  $(gum style --foreground 214 'iotPush not configured')"
        echo ""
        echo -e "  $(gum style --faint 'Get your key & topic: https://iotpush.com/settings')"
        echo ""

        ACTION=$(gum choose \
            --cursor="▸ " \
            --cursor.foreground 36 \
            --selected.foreground 36 \
            "➕  Set Up iotPush" \
            "↩   Back")
    fi

    case "$ACTION" in
        *"Test"*)
            echo ""
            echo -e "  ${DIM}Sending test push...${NC}"
            HOSTNAME_DISPLAY=$(hostname)
            RESP=$(curl -sfL --connect-timeout 5 \
                -H "Authorization: Bearer $CURRENT_KEY" \
                -H "Content-Type: application/json" \
                -d "{\"title\":\"🧪 Test from $HOSTNAME_DISPLAY\",\"message\":\"iotPush is working! Sent from Pi Zero-Trust setup TUI.\",\"priority\":\"normal\"}" \
                "https://iotpush.com/api/push/$CURRENT_TOPIC" 2>/dev/null) && {
                echo -e "  $(gum style --foreground 76 '✓ Push sent successfully')"
                echo -e "  $(gum style --faint "$RESP")"
            } || {
                echo -e "  $(gum style --foreground 214 '✗ Push failed — check credentials')"
            }
            ;;

        *"Update"*|*"Set Up"*)
            echo ""
            echo -e "  $(gum style --faint 'Enter your iotPush credentials')"
            echo -e "  $(gum style --faint 'Get them at: https://iotpush.com/settings')"
            echo ""

            NEW_KEY=$(gum_input "  API Key: " "${CURRENT_KEY}" "--password")
            NEW_TOPIC=$(gum_input "  Topic: " "${CURRENT_TOPIC}")

            if [ -z "$NEW_KEY" ] || [ -z "$NEW_TOPIC" ]; then
                echo -e "  $(gum style --foreground 214 'Both fields required.')"
                return
            fi

            # Validate against API
            echo ""
            echo -e "  ${DIM}Verifying credentials...${NC}"
            RESP=$(curl -sfL --connect-timeout 5 \
                -H "Authorization: Bearer $NEW_KEY" \
                -H "Content-Type: application/json" \
                -d '{"title":"Pi Setup","message":"iotPush credentials verified!"}' \
                "https://iotpush.com/api/push/$NEW_TOPIC" 2>/dev/null) && {
                echo -e "  $(gum style --foreground 76 '✓ Credentials valid — test push delivered')"
            } || {
                echo -e "  $(gum style --foreground 214 '⚠ Could not verify — saving anyway')"
            }

            # Save to .env
            if [ -f "$ENV_FILE" ]; then
                sed -i "s|^IOTPUSH_API_KEY=.*|IOTPUSH_API_KEY=${NEW_KEY}|" "$ENV_FILE"
                sed -i "s|^IOTPUSH_TOPIC=.*|IOTPUSH_TOPIC=${NEW_TOPIC}|" "$ENV_FILE"
            else
                mkdir -p /etc/pi-zero-trust
                cat > "$ENV_FILE" << EOF
IOTPUSH_API_KEY=${NEW_KEY}
IOTPUSH_TOPIC=${NEW_TOPIC}
EOF
                chmod 600 "$ENV_FILE"
            fi

            # Update pi-notify helper
            cat > /usr/local/bin/pi-notify << 'NOTIFYSCRIPT'
#!/bin/bash
source /etc/pi-zero-trust/.env
curl -s -d "$1" \
  -H "Authorization: Bearer $IOTPUSH_API_KEY" \
  https://www.iotpush.com/api/push/$IOTPUSH_TOPIC
NOTIFYSCRIPT
            chmod +x /usr/local/bin/pi-notify

            # Update settings.json
            if [ -f "$SETTINGS_FILE" ]; then
                /opt/pi-utility/venv/bin/python3 -c "
import json
with open('$SETTINGS_FILE') as f:
    s = json.load(f)
s['iotpush_api_key'] = '$NEW_KEY'
s['iotpush_topic'] = '$NEW_TOPIC'
with open('$SETTINGS_FILE', 'w') as f:
    json.dump(s, f, indent=2)
" 2>/dev/null || true
            fi

            # Restart agent to pick up new config
            systemctl restart pi-monitor 2>/dev/null || true

            echo -e "  $(gum style --foreground 76 '✓ iotPush configured and saved')"
            echo -e "  $(gum style --faint '  Config: $ENV_FILE')"
            echo -e "  $(gum style --faint '  Helper: /usr/local/bin/pi-notify')"
            ;;

        *"Disable"*)
            echo ""
            gum confirm --default=false "  Remove iotPush credentials?" || return
            if [ -f "$ENV_FILE" ]; then
                sed -i 's|^IOTPUSH_API_KEY=.*|IOTPUSH_API_KEY=|' "$ENV_FILE"
                sed -i 's|^IOTPUSH_TOPIC=.*|IOTPUSH_TOPIC=|' "$ENV_FILE"
            fi
            if [ -f "$SETTINGS_FILE" ]; then
                /opt/pi-utility/venv/bin/python3 -c "
import json
with open('$SETTINGS_FILE') as f:
    s = json.load(f)
s['notifications_enabled'] = False
with open('$SETTINGS_FILE', 'w') as f:
    json.dump(s, f, indent=2)
" 2>/dev/null || true
            fi
            systemctl restart pi-monitor 2>/dev/null || true
            echo -e "  $(gum style --foreground 76 '✓ iotPush disabled')"
            ;;

        *"Back"*) return ;;
    esac
    echo ""
}

do_status() {
    clear
    show_banner

    gum style --bold --foreground 36 "  📊 Agent Status"
    echo ""

    # Service
    if systemctl is-active --quiet pi-monitor 2>/dev/null; then
        echo -e "  Service:   $(gum style --foreground 76 '● Running')"
    else
        echo -e "  Service:   $(gum style --foreground 214 '● Not running')"
    fi

    # Uptime
    if [ -f /etc/pi-zero-trust/.env ]; then
        INSTALLED_HOSTNAME=$(hostname)
        INSTALLED_TOKEN=$(grep '^PI_API_TOKEN=' /etc/pi-zero-trust/.env 2>/dev/null | cut -d= -f2)
        if command -v tailscale &>/dev/null; then
            INSTALLED_IP=$(tailscale ip -4 2>/dev/null || hostname -I | awk '{print $1}')
        else
            INSTALLED_IP=$(hostname -I | awk '{print $1}')
        fi

        echo -e "  Hostname:  $(gum style --foreground 76 "$INSTALLED_HOSTNAME")"
        echo -e "  IP:        $(gum style --foreground 76 "$INSTALLED_IP")"
        echo -e "  API:       $(gum style --foreground 76 "http://$INSTALLED_IP:8080")"
        echo -e "  Token:     $(gum style --foreground 214 "${INSTALLED_TOKEN:0:8}...")"
    else
        echo -e "  Config:    $(gum style --foreground 214 'Not found — agent not installed?')"
    fi

    echo ""

    # Quick health check
    HEALTH_RESULT=$(curl -sfL --connect-timeout 3 "http://${INSTALLED_IP:-localhost}:8080/health" 2>/dev/null) && {
        echo -e "  Health:    $(gum style --foreground 76 '✓ Responding')"
        echo -e "  $(gum style --faint "$HEALTH_RESULT")"
    } || {
        echo -e "  Health:    $(gum style --foreground 214 '⚠ Not responding')"
    }

    echo ""
    gum confirm "  View recent logs?" && {
        echo ""
        journalctl -u pi-monitor -n 30 --no-pager
    }
    echo ""
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────
main() {
    # Must be root
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Please run as root: sudo bash $0${NC}"
        exit 1
    fi

    ensure_gum

    while true; do
        clear
        show_banner

        # Detect current state
        AGENT_INSTALLED=false
        [ -f /etc/pi-zero-trust/.env ] && AGENT_INSTALLED=true

        if [ "$AGENT_INSTALLED" = true ]; then
            CHOICE=$(gum choose \
                --cursor="▸ " \
                --cursor.foreground 36 \
                --selected.foreground 36 \
                --height 8 \
                "📊  Status" \
                "🔔  iotPush" \
                "🔄  Update Agent" \
                "🗑   Uninstall Agent" \
                "🚪  Exit")
        else
            CHOICE=$(gum choose \
                --cursor="▸ " \
                --cursor.foreground 36 \
                --selected.foreground 36 \
                --height 6 \
                "🚀  Install Agent" \
                "🚪  Exit")
        fi

        case "$CHOICE" in
            *"Install"*) do_install ;;
            *"Status"*)  do_status ;;
            *"iotPush"*)  do_iotpush ;;
            *"Update"*)  do_update ;;
            *"Uninstall"*) do_uninstall ;;
            *"Exit"*)    echo -e "\n$(gum style --faint 'Bye! 👋')\n"; exit 0 ;;
            *)           exit 0 ;;
        esac

        # Pause before returning to menu
        echo ""
        gum confirm "  Return to menu?" || exit 0
    done
}

main "$@"
