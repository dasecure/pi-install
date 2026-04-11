#!/bin/bash
# Pi Zero-Trust Agent v3.0 - Interactive TUI Setup
# Uses gum for beautiful terminal prompts
# Usage: curl -fsSL https://raw.githubusercontent.com/dasecure/pi-install/main/setup.sh | sudo bash
#   or:  sudo bash setup.sh

set -uo pipefail
trap 'echo "${RED}Error at line $LINENO: $BASH_COMMAND${NC}" >&2' ERR

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
LOG_FILE="/var/log/pi-setup.log"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE" 2>/dev/null || true; }

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
                "https://www.iotpush.com/api/push/$IOTPUSH_TOPIC" 2>/dev/null) && {
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
                    "https://www.iotpush.com/api/push/$IOTPUSH_TOPIC_VAL" 2>/dev/null) && {
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
    _show_qr "${INSTALLED_HOSTNAME:-$HOSTNAME_VAL}" "${INSTALLED_IP}" "${INSTALLED_TOKEN}" "$( [ "$TAILSCALE_ONLY" = "true" ] && echo 'pi' || echo 'vps')"

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

    # Get agent address
    if command -v tailscale &>/dev/null; then
        AGENT_IP=$(tailscale ip -4 2>/dev/null || hostname -I | awk '{print $1}')
    else
        AGENT_IP=$(hostname -I | awk '{print $1}')
    fi
    AGENT_URL="http://$AGENT_IP:8080"

    # Check current version via agent API
    HEALTH=$(curl -sfL --connect-timeout 5 "$AGENT_URL/health" 2>/dev/null)
    if [ -n "$HEALTH" ]; then
        CURRENT_VER=$(echo "$HEALTH" | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
        echo -e "  Current version: $(gum style --foreground 76 "${CURRENT_VER:-unknown}")"
    else
        echo -e "  $(gum style --foreground 214 "⚠ Agent not responding at $AGENT_IP")"
        echo -e "  $(gum style --faint 'Make sure pi-monitor is running')"
        echo ""
        return
    fi
    echo ""

    # Check for update via agent API
    API_TOKEN=$(grep '^PI_API_TOKEN=' /etc/pi-zero-trust/.env 2>/dev/null | cut -d= -f2)
    echo -e "  ${DIM}Checking for updates...${NC}"
    CHECK=$(curl -sfL --connect-timeout 10 \
        -H "X-API-Token: $API_TOKEN" \
        "$AGENT_URL/check-update" 2>/dev/null)

    if [ -n "$CHECK" ]; then
        UPDATE_AVAIL=$(echo "$CHECK" | grep -o '"update_available":[^,}]*' | cut -d: -f2)
        LATEST_VER=$(echo "$CHECK" | grep -o '"latest_version":"[^"]*"' | cut -d'"' -f4)
        MSG=$(echo "$CHECK" | grep -o '"latest_message":"[^"]*"' | cut -d'"' -f4)

        if [ "$UPDATE_AVAIL" = "true" ]; then
            echo -e "  $(gum style --foreground 214 "Update available: $LATEST_VER")"
            [ -n "$MSG" ] && echo -e "  $(gum style --faint "$MSG")"
        else
            echo -e "  $(gum style --foreground 76 '✓ Already up to date')"
            echo ""
            gum confirm "  Force update anyway?" || return
        fi
    else
        echo -e "  $(gum style --foreground 214 '⚠ Could not check for updates')"
    fi
    echo ""

    gum confirm "  Apply update?" || {
        echo -e "${YELLOW}Cancelled.${NC}"
        return
    }
    echo ""

    # Trigger update via agent API — agent handles download, install, restart
    echo -e "${GREEN}Updating via agent...${NC}"
    RESULT=$(curl -sfL --connect-timeout 10 --max-time 180 \
        -X POST \
        -H "X-API-Token: $API_TOKEN" \
        "$AGENT_URL/update" 2>/dev/null)

    if [ -n "$RESULT" ]; then
        SUCCESS=$(echo "$RESULT" | grep -o '"success":[^,}]*' | cut -d: -f2)
        MSG=$(echo "$RESULT" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
        if [ "$SUCCESS" = "true" ]; then
            echo -e "  $(gum style --foreground 76 '✓ Update applied')"
            [ -n "$MSG" ] && echo -e "  $(gum style --faint "$MSG")"
            echo ""
            echo -e "  $(gum style --faint 'Agent is restarting...')"
            sleep 5
            # Verify it came back
            NEW_HEALTH=$(curl -sfL --connect-timeout 15 "$AGENT_URL/health" 2>/dev/null)
            if [ -n "$NEW_HEALTH" ]; then
                NEW_VER=$(echo "$NEW_HEALTH" | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
                echo -e "  $(gum style --foreground 76 "✓ Agent running — version ${NEW_VER:-unknown}")"
            else
                echo -e "  $(gum style --foreground 214 '⚠ Agent still restarting — give it a moment')"
            fi
        else
            echo -e "  $(gum style --foreground 214 '✗ Update failed')"
            [ -n "$MSG" ] && echo -e "  $(gum style --faint "$MSG")"
        fi
    else
        echo -e "  $(gum style --foreground 214 '✗ Could not reach agent for update')"
        echo -e "  $(gum style --faint 'Check: journalctl -u pi-monitor -n 20')"
    fi
    echo ""
    echo -e "  $(gum style --faint 'Returning to menu...')"
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
                "https://www.iotpush.com/api/push/$CURRENT_TOPIC" 2>/dev/null) && {
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
                "https://www.iotpush.com/api/push/$NEW_TOPIC" 2>/dev/null) && {
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

            # Update settings.json — try python, then jq, then inline bash
            _settings_updated=false
            if [ -f "$SETTINGS_FILE" ]; then
                if command -v /opt/pi-utility/venv/bin/python3 &>/dev/null; then
                    /opt/pi-utility/venv/bin/python3 -c "
import json
with open('$SETTINGS_FILE') as f:
    s = json.load(f)
s['iotpush_api_key'] = '$NEW_KEY'
s['iotpush_topic'] = '$NEW_TOPIC'
s['notifications_enabled'] = True
with open('$SETTINGS_FILE', 'w') as f:
    json.dump(s, f, indent=2)
" && _settings_updated=true
                fi
                if [ "$_settings_updated" = false ] && command -v jq &>/dev/null; then
                    jq --arg k "$NEW_KEY" --arg t "$NEW_TOPIC" \
                       '. + {"iotpush_api_key":\$k, "iotpush_topic":\$t, "notifications_enabled":true}' \
                       "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE" && _settings_updated=true
                fi
                if [ "$_settings_updated" = false ]; then
                    # Fallback: rewrite the whole file preserving existing keys
                    cat > "$SETTINGS_FILE" << 'SETTINGSJSON'
{
  "notifications_enabled": true,
  "notify_on_boot": true,
  "notify_on_reboot": true,
  "notify_on_update": true,
  "notify_cooldown_minutes": 5,
  "tailscale_only": false,
  "iotpush_api_key": "PLACEHOLDER_KEY",
  "iotpush_topic": "PLACEHOLDER_TOPIC"
}
SETTINGSJSON
                    sed -i "s|PLACEHOLDER_KEY|$NEW_KEY|" "$SETTINGS_FILE"
                    sed -i "s|PLACEHOLDER_TOPIC|$NEW_TOPIC|" "$SETTINGS_FILE"
                fi
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

do_tailscale() {
    clear
    show_banner

    gum style --bold --foreground 36 "  🔗 Tailscale"
    echo ""

    if command -v tailscale &>/dev/null; then
        # Show current status
        TS_STATUS=$(tailscale status 2>/dev/null || echo "not connected")
        TS_IP=$(tailscale ip -4 2>/dev/null || echo "N/A")
        TS_VERSION=$(tailscale version 2>/dev/null | head -1)

        echo -e "  Status:   $(gum style --foreground 76 '● Installed')"
        echo -e "  Version:  $(gum style --faint "$TS_VERSION")"
        echo -e "  IP:       $(gum style --foreground 76 "$TS_IP")"
        echo -e "  $(gum style --faint 'Install URL: https://login.tailscale.com/admin/settings/keys')"
        echo ""

        # Check if connected — tailscale status returns exit code 0 when connected
        TS_CONNECTED=true
        tailscale status &>/dev/null || TS_CONNECTED=false

        if [ "$TS_CONNECTED" = false ]; then
            echo -e "  $(gum style --foreground 214 '● Disconnected')"
            echo ""
            ACTION=$(gum choose \
                --cursor="▸ " \
                --cursor.foreground 36 \
                --selected.foreground 36 \
                "🔐  Connect (Auth Key)" \
                "🌐  Connect (Interactive Login)" \
                "🔄  Update Tailscale" \
                "🗑   Uninstall Tailscale" \
                "↩   Back")
        else
            echo -e "  $(gum style --foreground 76 '● Connected')"
            echo ""
            ACTION=$(gum choose \
                --cursor="▸ " \
                --cursor.foreground 36 \
                --selected.foreground 36 \
                "📊  Show Status" \
                "🔑  Generate Auth Key Info" \
                "🔄  Update Tailscale" \
                "🔌  Disconnect" \
                "🗑   Uninstall Tailscale" \
                "↩   Back")
        fi
    else
        echo -e "  Status: $(gum style --faint '○ Not installed')"
        echo ""
        echo -e "  $(gum style --faint 'Tailscale creates a secure mesh VPN for your devices')"
        echo -e "  $(gum style --faint 'All traffic is encrypted — no open ports needed')"
        echo ""

        ACTION=$(gum choose \
            --cursor="▸ " \
            --cursor.foreground 36 \
            --selected.foreground 36 \
            "📦  Install Tailscale" \
            "↩   Back")
    fi

    case "$ACTION" in
        *"Install"*)
            echo ""
            echo -e "${YELLOW}Installing Tailscale...${NC}"
            curl -fsSL https://tailscale.com/install.sh | sh
            echo ""
            echo -e "  $(gum style --foreground 76 '✓ Tailscale installed')"
            echo ""

            # Offer to connect
            gum confirm "  Connect to Tailscale now?" && {
                echo ""
                AUTH_KEY=$(gum input --prompt "  Auth Key (tskey-auth-...): " --password)
                if [ -n "$AUTH_KEY" ]; then
                    HOSTNAME_VAL=$(hostname)
                    if tailscale status &>/dev/null; then
                        NEW_IP=$(tailscale ip -4 2>/dev/null || echo "pending")
                        echo -e "  $(gum style --foreground 76 '✓ Already connected!')"
                        echo -e "  Tailscale IP: $(gum style --foreground 76 "$NEW_IP")"
                    else
                        tailscale up --authkey="$AUTH_KEY" --ssh --hostname="$HOSTNAME_VAL" 2>/dev/null && {
                            NEW_IP=$(tailscale ip -4 2>/dev/null || echo "pending")
                            echo -e "  $(gum style --foreground 76 '✓ Connected!')"
                            echo -e "  Tailscale IP: $(gum style --foreground 76 "$NEW_IP")"
                        } || {
                            echo -e "  $(gum style --foreground 214 '✗ Connection failed — try interactive login')"
                            echo -e "  $(gum style --faint 'Run: tailscale up')"
                        }
                    fi
                else
                    echo -e "  $(gum style --faint 'Skipped — run `tailscale up` to connect later')"
                fi
            }
            echo ""
            ;;

        *"Connect (Auth Key)"*)
            echo ""
            AUTH_KEY=$(gum input --prompt "  Auth Key (tskey-auth-...): " --password)
            if [ -n "$AUTH_KEY" ]; then
                HOSTNAME_VAL=$(hostname)
                if tailscale status &>/dev/null; then
                    NEW_IP=$(tailscale ip -4 2>/dev/null || echo "pending")
                    echo -e "  $(gum style --foreground 76 '✓ Already connected! IP: $NEW_IP')"
                else
                    echo -e "  ${YELLOW}Connecting...${NC}"
                    tailscale up --authkey="$AUTH_KEY" --ssh --hostname="$HOSTNAME_VAL" 2>/dev/null && {
                        NEW_IP=$(tailscale ip -4 2>/dev/null || echo "pending")
                        echo -e "  $(gum style --foreground 76 '✓ Connected!')"
                        echo -e "  Tailscale IP: $(gum style --foreground 76 "$NEW_IP")"
                    } || {
                        echo -e "  $(gum style --foreground 214 '✗ Connection failed')"
                    }
                fi
            fi
            echo ""
            ;;

        *"Connect (Interactive"*)
            echo ""
            echo -e "  ${YELLOW}Starting interactive login...${NC}"
            echo -e "  $(gum style --faint 'A login URL will appear — open it in your browser')"
            echo ""
            tailscale up --ssh 2>&1 || true
            echo ""
            NEW_IP=$(tailscale ip -4 2>/dev/null || echo "N/A")
            echo -e "  Tailscale IP: $(gum style --foreground 76 "$NEW_IP")"
            echo ""
            ;;

        *"Status"*)
            echo ""
            tailscale status
            echo ""
            echo ""
            ;;

        *"Auth Key Info"*)
            echo ""
            echo -e "  $(gum style --bold 'Generate Auth Keys at:')"
            echo -e "  $(gum style --foreground 36 'https://login.tailscale.com/admin/settings/keys')"
            echo ""
            echo -e "  $(gum style --faint 'Tip: Create a reusable key for multiple devices')"
            echo ""
            ;;

        *"Update"*)
            echo ""
            echo -e "  ${YELLOW}Updating Tailscale...${NC}"
            curl -fsSL https://tailscale.com/install.sh | sh
            echo -e "  $(gum style --foreground 76 '✓ Tailscale updated')"
            NEW_VER=$(tailscale version 2>/dev/null | head -1)
            echo -e "  Version: $(gum style --foreground 76 "$NEW_VER")"
            echo ""
            ;;

        *"Disconnect"*)
            echo ""
            gum confirm "  Disconnect from Tailscale?" || return
            tailscale down 2>/dev/null
            echo -e "  $(gum style --foreground 76 '✓ Disconnected')"
            echo ""
            ;;

        *"Uninstall"*)
            echo ""
            gum confirm --default=false "  Uninstall Tailscale? This removes mesh VPN access." || return
            echo ""
            tailscale down 2>/dev/null || true
            tailscale logout 2>/dev/null || true
            systemctl stop tailscaled 2>/dev/null || true
            systemctl disable tailscaled 2>/dev/null || true
            apt-get remove -y -qq tailscale 2>/dev/null || true
            echo -e "  $(gum style --foreground 76 '✓ Tailscale removed')"
            echo -e "  $(gum style --faint 'Note: agent may need reconfiguration without Tailscale')"
            echo ""
            ;;

        *"Back"*) return ;;
    esac
}

do_remote_desktop() {
    clear
    show_banner

    gum style --bold --foreground 36 "  🖥  Remote Desktop (VNC)"
    echo ""
    gum style --faint "  Access your device desktop from iOS via Tailscale + VNC"
    echo ""

    # Detect current state
    VNC_INSTALLED=false
    DESKTOP_INSTALLED=false
    VNC_RUNNING=false

    command -v vncserver &>/dev/null && VNC_INSTALLED=true
    dpkg -l xfce4 &>/dev/null 2>&1 && dpkg -l xfce4 2>/dev/null | grep -q '^ii' && DESKTOP_INSTALLED=true
    systemctl is-active --quiet vncserver 2>/dev/null && VNC_RUNNING=true

    # Show current state
    if [ "$VNC_RUNNING" = true ]; then
        echo -e "  Status: $(gum style --foreground 76 '● VNC is running')"
        if command -v tailscale &>/dev/null; then
            TS_IP=$(tailscale ip -4 2>/dev/null || echo "N/A")
        else
            TS_IP=$(hostname -I | awk '{print $1}')
        fi
        echo -e "  Connect: $(gum style --foreground 76 "$TS_IP:5901")"
        echo -e "  $(gum style --faint 'Use RealVNC Viewer or Screens 5 on iOS')"
    elif [ "$VNC_INSTALLED" = true ]; then
        echo -e "  Status: $(gum style --foreground 214 '● VNC installed but not running')"
    else
        echo -e "  Status: $(gum style --faint '○ Not installed')"
    fi
    echo ""

    if [ "$VNC_RUNNING" = true ]; then
        ACTION=$(gum choose \
            --cursor="▸ " \
            --cursor.foreground 36 \
            --selected.foreground 36 \
            "🛑  Stop VNC" \
            "🔑  Change VNC Password" \
            "🗑   Uninstall Remote Desktop" \
            "↩   Back")
    elif [ "$VNC_INSTALLED" = true ]; then
        ACTION=$(gum choose \
            --cursor="▸ " \
            --cursor.foreground 36 \
            --selected.foreground 36 \
            "▶️   Start VNC" \
            "🔑  Change VNC Password" \
            "🗑   Uninstall Remote Desktop" \
            "↩   Back")
    else
        ACTION=$(gum choose \
            --cursor="▸ " \
            --cursor.foreground 36 \
            --selected.foreground 36 \
            "📦  Install Remote Desktop" \
            "↩   Back")
    fi

    case "$ACTION" in
        *"Install"*)
            _install_remote_desktop
            ;;

        *"Start"*)
            echo ""
            # Ensure service file exists
            if [ ! -f /etc/systemd/system/vncserver.service ]; then
                cat > /etc/systemd/system/vncserver.service << 'VNCSVC'
[Unit]
Description=TigerVNC server (display :1)
After=network.target

[Service]
Type=forking
User=root
ExecStartPre=-/usr/bin/vncserver -kill :1
ExecStart=/usr/bin/vncserver :1 -geometry 1280x720 -depth 24 -localhost no
ExecStop=/usr/bin/vncserver -kill :1
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
VNCSVC
                systemctl daemon-reload
                systemctl enable vncserver
            fi
            systemctl start vncserver 2>/dev/null && {
                echo -e "  $(gum style --foreground 76 '✓ VNC started')"
            } || {
                echo -e "  $(gum style --foreground 214 '✗ Failed to start VNC')"
                echo -e "  $(gum style --faint 'Try: journalctl -u vncserver -n 10')"
            }
            echo ""
            gum style --faint "  Connect with VNC client to $(hostname -I | awk '{print $1}'):5901"
            echo ""
            ;;

        *"Stop"*)
            echo ""
            systemctl stop vncserver 2>/dev/null
            vncserver -kill :1 2>/dev/null || true
            echo -e "  $(gum style --foreground 76 '✓ VNC stopped')"
            echo ""
            ;;

        *"Password"*)
            echo ""
            _set_vnc_password
            ;;

        *"Uninstall"*)
            echo ""
            gum confirm --default=false "  Uninstall remote desktop? (removes VNC + XFCE)" || return
            echo ""
            echo -e "  ${YELLOW}Stopping VNC...${NC}"
            systemctl stop vncserver 2>/dev/null || true
            systemctl disable vncserver 2>/dev/null || true
            rm -f /etc/systemd/system/vncserver.service
            systemctl daemon-reload
            vncserver -kill :1 2>/dev/null || true

            echo -e "  ${YELLOW}Removing packages...${NC}"
            apt-get remove -y -qq tigervnc-standalone-server xfce4 xfce4-goodies 2>/dev/null || true
            apt-get autoremove -y -qq 2>/dev/null || true
            rm -rf /root/.vnc /home/*/.vnc

            echo -e "  $(gum style --foreground 76 '✓ Remote desktop removed')"
            echo ""
            ;;

        *"Back"*) return ;;
    esac
}

_install_remote_desktop() {
    echo ""
    gum style --bold "  This will install:"
    echo -e "    $(gum style --faint '•') XFCE4 desktop environment (~300MB)"
    echo -e "    $(gum style --faint '•') TigerVNC server"
    echo -e "    $(gum style --faint '•') Systemd service (auto-start)"
    echo ""

    if command -v tailscale &>/dev/null; then
        echo -e "  $(gum style --foreground 76 '🔒 Secured: VNC will only listen on Tailscale (100.x.x.x)')"
    else
        echo -e "  $(gum style --foreground 214 '⚠ No Tailscale — VNC will listen on all interfaces')"
    fi
    echo ""

    gum confirm "  Continue with installation?" || return
    echo ""

    # ── Step 1: Desktop environment ──
    STEP=1
    TOTAL=4

    echo -e "${YELLOW}[$STEP/$TOTAL] Installing XFCE4 desktop environment...${NC}"
    echo -e "  $(gum style --faint 'This may take a few minutes on first install...')"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq

    # Core desktop packages
    DESKTOP_PKGS="xfce4 dbus-x11 xterm"
    echo -e "  $(gum style --faint 'Installing core packages...')"
    if ! apt-get install -y $DESKTOP_PKGS 2>&1; then
        echo -e "  $(gum style --foreground 214 '⚠ Retrying with --fix-broken...')"
        apt-get --fix-broken install -y
        apt-get install -y $DESKTOP_PKGS
    fi

    # Optional goodies (non-fatal)
    echo -e "  $(gum style --faint 'Installing extras...')"
    apt-get install -y xfce4-goodies 2>/dev/null || true

    # Verify critical binaries
    if ! command -v startxfce4 &>/dev/null; then
        echo -e "  $(gum style --foreground 196 '✗ startxfce4 not found — XFCE4 install may have failed')"
        echo -e "  $(gum style --faint '  Try: apt-get install -y xfce4 xfce4-session')"
    fi
    if ! command -v xterm &>/dev/null; then
        echo -e "  $(gum style --foreground 196 '✗ xterm not found')"
    fi
    echo -e "  $(gum style --foreground 76 '✓ XFCE4 installed')"
    echo ""

    # ── Step 2: VNC server ──
    STEP=$((STEP + 1))
    echo -e "${YELLOW}[$STEP/$TOTAL] Installing TigerVNC...${NC}"
    if ! apt-get install -y tigervnc-standalone-server tigervnc-common 2>&1; then
        echo -e "  $(gum style --foreground 214 '⚠ Retrying...')"
        apt-get --fix-broken install -y
        apt-get install -y tigervnc-standalone-server tigervnc-common
    fi
    # Verify binary exists (package may report installed but binary missing)
    if ! command -v vncserver &>/dev/null; then
        apt-get install --reinstall -y tigervnc-standalone-server
    fi
    if ! command -v vncserver &>/dev/null; then
        echo -e "  $(gum style --foreground 196 '✗ vncserver binary not found after install')"
        return 1
    fi
    echo -e "  $(gum style --foreground 76 '✓ TigerVNC installed')"
    echo ""

    # ── Step 3: Configure ──
    STEP=$((STEP + 1))
    echo -e "${YELLOW}[$STEP/$TOTAL] Configuring VNC...${NC}"

    # Set VNC password
    _set_vnc_password

    # Determine the user
    VNC_USER="${SUDO_USER:-root}"
    VNC_HOME=$(eval echo ~"$VNC_USER")

    # Create VNC config directory
    mkdir -p "$VNC_HOME/.vnc"
    chown "$VNC_USER" "$VNC_HOME/.vnc"

    # xstartup script
    cat > "$VNC_HOME/.vnc/xstartup" << 'XSTARTUP'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export XDG_SESSION_TYPE=x11

[ -f /etc/X11/xinit/xinitrc ] && . /etc/X11/xinit/xinitrc

# Start XFCE
exec startxfce4
XSTARTUP
    chmod +x "$VNC_HOME/.vnc/xstartup"
    chown "$VNC_USER" "$VNC_HOME/.vnc/xstartup"

    # VNC server config — restrict to localhost (Tailscale/proxy will handle external)
    cat > "$VNC_HOME/.vnc/config" << 'VNCCONFIG'
## Security types
SecurityTypes=VncAuth

## Listen on all interfaces (Tailscale provides network-level security)
localhost=no

## Display settings
geometry=1280x720
depth=24
VNCCONFIG
    chown "$VNC_USER" "$VNC_HOME/.vnc/config"

    echo -e "  $(gum style --foreground 76 '✓ VNC configured')"
    echo -e "  $(gum style --faint '  Listening: localhost only (port 5901)')"
    echo ""

    # ── Step 4: Systemd service ──
    STEP=$((STEP + 1))
    echo -e "${YELLOW}[$STEP/$TOTAL] Setting up systemd service...${NC}"

    cat > /etc/systemd/system/vncserver.service << 'VNCSERVICE'
[Unit]
Description=TigerVNC server (display :1)
After=network.target

[Service]
Type=forking
User=root
ExecStartPre=-/usr/bin/vncserver -kill :1
ExecStart=/usr/bin/vncserver :1 -geometry 1280x720 -depth 24 -localhost no
ExecStop=/usr/bin/vncserver -kill :1
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
VNCSERVICE

    systemctl daemon-reload
    systemctl enable vncserver
    systemctl start vncserver

    if ! systemctl is-active --quiet vncserver 2>/dev/null; then
        echo -e "  $(gum style --foreground 214 '⚠ VNC service failed to start. Diagnostics:')"
        journalctl -u vncserver -n 10 --no-pager 2>/dev/null | sed 's/^/    /'
        echo ""
        echo -e "  $(gum style --faint 'Try manually: vncserver :1 -geometry 1280x720 -depth 24')"
    else
        echo -e "  $(gum style --foreground 76 '✓ Service installed and started')"
    fi
    echo ""

    # ── Done ──
    if command -v tailscale &>/dev/null; then
        CONNECT_IP=$(tailscale ip -4 2>/dev/null || echo "$(hostname -I | awk '{print $1}')")
    else
        CONNECT_IP=$(hostname -I | awk '{print $1}')
    fi

    echo ""
    gum style \
        --border double \
        --border-foreground 76 \
        --margin "1 2" \
        --padding "1 4" \
        "$(gum style --bold --foreground 76 '🖥  Remote Desktop Ready!')"
    echo ""
    echo -e "  Connect from iOS or Mac:"
    echo -e "    $(gum style --bold '1.') Install $(gum style --foreground 36 'RealVNC Viewer') (free) from App Store"
    echo -e "    $(gum style --bold '2.') Connect to:"
    echo -e "       $(gum style --foreground 76 '$CONNECT_IP:5901')"
    echo ""
    echo -e "  $(gum style --faint 'Password: the VNC password you set during installation')"
    echo ""

    # Send iotPush notification
    if [ -f /etc/pi-zero-trust/.env ]; then
        IOTPUSH_KEY_VAL=$(grep '^IOTPUSH_API_KEY=' /etc/pi-zero-trust/.env 2>/dev/null | cut -d= -f2)
        IOTPUSH_TOPIC_VAL=$(grep '^IOTPUSH_TOPIC=' /etc/pi-zero-trust/.env 2>/dev/null | cut -d= -f2)
        if [ -n "$IOTPUSH_KEY_VAL" ] && [ -n "$IOTPUSH_TOPIC_VAL" ]; then
            curl -sfL --connect-timeout 5 \
                -H "Authorization: Bearer $IOTPUSH_KEY_VAL" \
                -H "Content-Type: application/json" \
                -d '{"title":"🖥 Remote Desktop Ready","message":"VNC is running. Connect via SSH tunnel.","priority":"normal"}' \
                "https://www.iotpush.com/api/push/$IOTPUSH_TOPIC_VAL" 2>/dev/null || true
        fi
    fi
}

_set_vnc_password() {
    echo -e "  $(gum style --bold 'Set VNC password')"
    echo -e "  $(gum style --faint 'This password is required to connect from your iOS device')"
    echo ""

    VNC_PASS=$(gum input --prompt "  VNC Password: " --password)
    if [ -z "$VNC_PASS" ]; then
        echo -e "  $(gum style --foreground 214 'Password cannot be empty')"
        return 1
    fi

    VNC_USER="${SUDO_USER:-root}"
    VNC_HOME=$(eval echo ~"$VNC_USER")
    mkdir -p "$VNC_HOME/.vnc"

    # Set password using vncpasswd
    echo "$VNC_PASS" | vncpasswd -f > "$VNC_HOME/.vnc/passwd"
    chmod 600 "$VNC_HOME/.vnc/passwd"
    chown "$VNC_USER" "$VNC_HOME/.vnc/passwd"

    # Also set view-only password to no
    printf '%s\nn\n' "$VNC_PASS" | vncpasswd 2>/dev/null || true

    echo -e "  $(gum style --foreground 76 '✓ VNC password set')"
    echo ""
}

# ──────────────────────────────────────────────
# Shared QR code renderer
# ──────────────────────────────────────────────
_show_qr() {
    local hostname="$1" ip="$2" token="$3" dtype="${4:-vps}"
    local qr_data="{\"h\":\"$hostname\",\"a\":\"$ip\",\"p\":8080,\"t\":\"$token\",\"d\":\"$dtype\"}"

    if [ -x /opt/pi-utility/venv/bin/python3 ]; then
        /opt/pi-utility/venv/bin/python3 -c "
import sys
try:
    import qrcode
    qr = qrcode.QRCode(border=1)
    qr.add_data(sys.argv[1])
    qr.make(fit=True)
    qr.print_ascii(invert=True)
except ImportError:
    print('qrcode not installed')
" "$qr_data" 2>/dev/null
    elif command -v qrencode &>/dev/null; then
        qrencode -t ANSI "$qr_data"
    else
        echo -e "  $(gum style --faint 'QR tools not available. Raw data:')"
        echo -e "  $qr_data"
    fi
    echo ""
    echo -e "  $(gum style --foreground 36 '📱 Scan in PiControl app → Settings → Scan QR')"
}

do_qrcode() {
    clear
    show_banner

    gum style --bold --foreground 36 "  📱 QR Code for PiControl"
    echo ""

    if [ ! -f /etc/pi-zero-trust/.env ]; then
        echo -e "  $(gum style --foreground 214 'Agent not installed — no QR to show')"
        echo ""
        return
    fi

    TOKEN=$(grep '^PI_API_TOKEN=' /etc/pi-zero-trust/.env 2>/dev/null | cut -d= -f2)
    HOSTNAME_VAL=$(grep '^PI_HOSTNAME=' /etc/pi-zero-trust/.env 2>/dev/null | cut -d= -f2)
    HOSTNAME_VAL="${HOSTNAME_VAL:-$(hostname)}"
    TAILSCALE_ONLY=$(grep '^TAILSCALE_ONLY=' /etc/pi-zero-trust/.env 2>/dev/null | cut -d= -f2)

    if command -v tailscale &>/dev/null; then
        IP=$(tailscale ip -4 2>/dev/null || hostname -I | awk '{print $1}')
    else
        IP=$(hostname -I | awk '{print $1}')
    fi

    DEVICE_TYPE=$([ "$TAILSCALE_ONLY" = "true" ] && echo 'pi' || echo 'vps')

    echo -e "  Hostname: $(gum style --foreground 76 "$HOSTNAME_VAL")"
    echo -e "  IP:       $(gum style --foreground 76 "$IP")"
    echo -e "  Token:    $(gum style --foreground 214 "${TOKEN:0:8}...")"
    echo ""

    _show_qr "$HOSTNAME_VAL" "$IP" "$TOKEN" "$DEVICE_TYPE"
    echo ""
    echo -e "  $(gum style --foreground 36 '📱 Scan in PiControl app → Settings → Scan QR')"
    echo ""
    echo -e "  $(gum style --faint 'Press any key to return to menu...')"
    read -rsn1
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
                --height 14 \
                "📊  Status" \
                "📱  Show QR Code" \
                "🔔  iotPush" \
                "🔗  Tailscale" \
                "🖥   Remote Desktop" \
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
            *"QR"*)      do_qrcode ;;
            *"iotPush"*)  do_iotpush ;;
            *"Tailscale"*) do_tailscale ;;
            *"Remote"*)  do_remote_desktop ;;
            *"Update"*)  do_update ;;
            *"Uninstall"*) do_uninstall ;;
            *"Exit"*)    echo -e "\n$(gum style --faint 'Bye! 👋')\n"; exit 0 ;;
            *)           exit 0 ;;
        esac

        # Brief pause before returning to menu
        sleep 1
    done
}

main "$@"
