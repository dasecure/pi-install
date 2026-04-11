#!/bin/bash
# Pi Zero-Trust Agent — Quick Install
# Usage: curl -fsSL https://raw.githubusercontent.com/dasecure/pi-install/main/start.sh | sudo bash
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

REPO="dasecure/pi-install"
BRANCH="main"
BINARY="/usr/local/bin/pi-agent"

echo -e "${GREEN}"
echo "╔════════════════════════════════════════════════════════╗"
echo "║       Pi Zero-Trust Agent — Quick Install             ║"
echo "╚════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Must be root ──
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root: curl ... | sudo bash${NC}"
    exit 1
fi

# ── Detect platform ──
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  GOARCH="amd64" ;;
    aarch64|arm64) GOARCH="arm64" ;;
    armv7l)  GOARCH="arm64" ;;  # Pi 4+ runs arm64
    *)       echo -e "${RED}Unsupported architecture: $ARCH${NC}"; exit 1 ;;
esac

# ── Try pre-built binary first ──
echo -e "${YELLOW}[1/2] Downloading pi-agent (${OS}-${GOARCH})...${NC}"
DOWNLOAD_URL="https://github.com/${REPO}/releases/latest/download/pi-agent-${OS}-${GOARCH}"
if curl -fsSL --connect-timeout 10 "$DOWNLOAD_URL" -o "$BINARY" 2>/dev/null; then
    chmod +x "$BINARY"
    echo -e "  ${GREEN}✓${NC} Downloaded pre-built binary"
else
    echo -e "  ${YELLOW}Pre-built binary not found, building from source...${NC}"

    # ── Install Go if needed ──
    if ! command -v go &>/dev/null; then
        echo -e "  Installing Go..."
        GO_VERSION="1.22.5"
        case "$ARCH" in
            x86_64)  GOARCH2="amd64" ;;
            aarch64|arm64) GOARCH2="arm64" ;;
            armv7l)  GOARCH2="armv6l" ;;
        esac
        curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GOARCH2}.tar.gz" | tar -C /usr/local -xzf -
        export PATH="/usr/local/go/bin:$PATH"
        echo -e "  ${GREEN}✓${NC} Go installed"
    else
        echo -e "  Go already installed"
    fi

    # ── Download source and build ──
    BUILD_DIR=$(mktemp -d)
    trap 'rm -rf "$BUILD_DIR"' EXIT
    BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"

    for f in main.go go.mod internal/config/config.go internal/agent/agent.go internal/install/install.go internal/iotpush/iotpush.go internal/system/system.go internal/tui/tui.go; do
        dest="$BUILD_DIR/$f"
        mkdir -p "$(dirname "$dest")"
        curl -fsSL "${BASE_URL}/${f}" -o "$dest" || {
            echo -e "${RED}Failed to download: $f${NC}"
            exit 1
        }
    done

    cd "$BUILD_DIR"
    go mod tidy 2>/dev/null
    go build -ldflags "-s -w" -o "$BINARY" . || {
        echo -e "${RED}Build failed${NC}"
        exit 1
    }
    echo -e "  ${GREEN}✓${NC} Built from source"
fi

# ── Launch TUI ──
echo ""
echo -e "${YELLOW}[2/2] Starting interactive setup...${NC}"
echo ""
"$BINARY"
