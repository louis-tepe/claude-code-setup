#!/bin/bash
set -e

# ==============================================================================
# Claude Code Setup — Multi-Provider Router v5
# ==============================================================================
# This script installs:
#   1. Multi-provider proxy (routes Sonnet/Haiku → GLM/MiniMax/etc., Opus → Anthropic)
#   2. Mode config files (proxy-modes/*.env)
#   3. Claude Code global config (settings, agents, statusline)
#   4. Shell integration (mode switching, proxy lifecycle)
#
# Supports: macOS and Linux
# ==============================================================================

BOLD="\033[1m"
GREEN="\033[92m"
YELLOW="\033[93m"
RED="\033[91m"
CYAN="\033[96m"
RESET="\033[0m"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROXY_DIR="$HOME/claude-code-proxy"
CLAUDE_DIR="$HOME/.claude"

info()  { echo -e "${CYAN}[INFO]${RESET} $1"; }
ok()    { echo -e "${GREEN}[OK]${RESET} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $1"; }
error() { echo -e "${RED}[ERROR]${RESET} $1"; exit 1; }

# ------------------------------------------------------------------------------
# Cleanup on failure
# ------------------------------------------------------------------------------
CLEANUP_PROXY=false

cleanup() {
    if [ "$CLEANUP_PROXY" = true ] && [ -d "$PROXY_DIR" ]; then
        warn "Installation failed — cleaning up $PROXY_DIR"
        rm -rf "$PROXY_DIR"
    fi
}
trap cleanup EXIT

# ------------------------------------------------------------------------------
# OS Detection
# ------------------------------------------------------------------------------
OS="$(uname -s)"
case "$OS" in
    Darwin) PLATFORM="macos" ;;
    Linux)  PLATFORM="linux" ;;
    *)      error "Unsupported OS: $OS. Only macOS and Linux are supported." ;;
esac

sed_inplace() {
    if [ "$PLATFORM" = "macos" ]; then
        sed -i.bak "$@"
    else
        sed -i "$@"
    fi
}

play_notification() {
    if [ "$PLATFORM" = "macos" ]; then
        echo 'afplay /System/Library/Sounds/Glass.aiff &'
    else
        echo '(command -v paplay &>/dev/null && paplay /usr/share/sounds/freedesktop/stereo/complete.oga &) 2>/dev/null || true'
    fi
}

echo ""
echo -e "${BOLD}================================================${RESET}"
echo -e "${BOLD}  Claude Code — Multi-Provider Router Installer${RESET}"
echo -e "${BOLD}================================================${RESET}"
echo ""
echo "Platform: $PLATFORM"
echo ""
echo "This will install:"
echo "  - Multi-provider proxy (GLM, MiniMax, MiMo, or any Anthropic-compatible API)"
echo "  - Claude Code config (agents, statusline)"
echo "  - Shell integration with 7 routing modes:"
echo "      claude-full  = Full Claude (all → Anthropic OAuth)"
echo "      glm-on       = Hybrid GLM (Sonnet → GLM-5.1, Haiku → GLM-4.7)"
echo "      minimax-on   = Hybrid MiniMax (Sonnet/Haiku → MiniMax M2.7)"
echo "      mimo-on      = Hybrid MiMo (Sonnet/Haiku → MiMo-V2.5-Pro)"
echo "      mix-on       = Split (Sonnet → GLM-5.1, Haiku → MiniMax M2.7)"
echo "      glm-full     = Full GLM (all → Z.AI direct)"
echo "      mimo-full    = Full MiMo (all → Xiaomi MiMo direct)"
echo ""

# ------------------------------------------------------------------------------
# Pre-requisites
# ------------------------------------------------------------------------------
info "Checking prerequisites..."

# Python 3
if command -v python3 &>/dev/null; then
    PYTHON_VERSION=$(python3 --version 2>&1 | awk '{print $2}')
    PYTHON_MAJOR=$(echo "$PYTHON_VERSION" | cut -d. -f1)
    PYTHON_MINOR=$(echo "$PYTHON_VERSION" | cut -d. -f2)

    if [ "$PYTHON_MAJOR" -lt 3 ] || ([ "$PYTHON_MAJOR" -eq 3 ] && [ "$PYTHON_MINOR" -lt 10 ]); then
        error "Python 3.10+ is required (found $PYTHON_VERSION). The proxy uses modern type hints (str | None)."
    fi
    ok "Python $PYTHON_VERSION found"
else
    if [ "$PLATFORM" = "macos" ]; then
        error "Python 3.10+ is required. Install it with: brew install python3"
    else
        error "Python 3.10+ is required. Install it with: sudo apt install python3 python3-venv"
    fi
fi

# pip / venv
if python3 -m pip --version &>/dev/null; then
    ok "pip found"
else
    if [ "$PLATFORM" = "linux" ]; then
        warn "pip not found — trying to install python3-venv..."
        if command -v apt &>/dev/null; then
            sudo apt install -y python3-pip python3-venv
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y python3-pip python3-virtualenv
        else
            error "pip is required. Install it with your package manager."
        fi
    else
        error "pip is required. Install it with: python3 -m ensurepip"
    fi
fi

# jq
if command -v jq &>/dev/null; then
    ok "jq found"
else
    warn "jq not found — installing..."
    if [ "$PLATFORM" = "macos" ]; then
        command -v brew &>/dev/null && brew install jq && ok "jq installed" || error "jq is required. Install Homebrew then: brew install jq"
    else
        command -v apt &>/dev/null && sudo apt install -y jq && ok "jq installed" || \
        command -v dnf &>/dev/null && sudo dnf install -y jq && ok "jq installed" || \
        error "jq is required. Install it with your package manager."
    fi
fi

# Claude Code
if command -v claude &>/dev/null; then
    ok "Claude Code found"
else
    warn "Claude Code not found in PATH"
    echo "  Install it with: npm install -g @anthropic-ai/claude-code"
fi

echo ""

# ------------------------------------------------------------------------------
# Install Proxy
# ------------------------------------------------------------------------------
info "Installing multi-provider proxy..."

if [ -d "$PROXY_DIR" ]; then
    warn "Proxy directory already exists at $PROXY_DIR"
    read -p "  Overwrite? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "Skipping proxy installation"
    else
        rm -rf "$PROXY_DIR"
    fi
fi

if [ ! -d "$PROXY_DIR" ]; then
    CLEANUP_PROXY=true
    mkdir -p "$PROXY_DIR"
    cp "$SCRIPT_DIR/proxy/proxy.py" "$PROXY_DIR/"
    cp "$SCRIPT_DIR/proxy/requirements.txt" "$PROXY_DIR/"
    cp "$SCRIPT_DIR/proxy/start-proxy.sh" "$PROXY_DIR/"
    chmod +x "$PROXY_DIR/start-proxy.sh"

    # .env — operational config only (port, log level)
    if [ ! -f "$PROXY_DIR/.env" ]; then
        cp "$SCRIPT_DIR/proxy/.env.example" "$PROXY_DIR/.env"
    fi
    ok "Proxy files copied to $PROXY_DIR"

    # Create venv and install dependencies
    info "Creating Python virtual environment..."
    python3 -m venv "$PROXY_DIR/venv" || error "Failed to create venv. On Linux: sudo apt install python3-venv"
    "$PROXY_DIR/venv/bin/pip" install -q -r "$PROXY_DIR/requirements.txt" || error "Failed to install Python dependencies"
    ok "Python dependencies installed"
    CLEANUP_PROXY=false
fi

echo ""

# ------------------------------------------------------------------------------
# Install Mode Files
# ------------------------------------------------------------------------------
info "Installing provider mode files..."

mkdir -p "$CLAUDE_DIR/proxy-modes"
for mode_file in "$SCRIPT_DIR/proxy-modes/"*.env; do
    [ -f "$mode_file" ] || continue
    cp "$mode_file" "$CLAUDE_DIR/proxy-modes/"
done
MODE_COUNT=$(ls "$SCRIPT_DIR/proxy-modes/"*.env 2>/dev/null | wc -l | tr -d ' ')
ok "$MODE_COUNT mode files installed to $CLAUDE_DIR/proxy-modes/"

echo ""

# ------------------------------------------------------------------------------
# API Keys
# ------------------------------------------------------------------------------
info "Configuring API keys..."

# Z.AI key
if [ -f "$CLAUDE_DIR/.zai-api-key" ] && [ -s "$CLAUDE_DIR/.zai-api-key" ]; then
    ok "Z.AI API key already configured"
else
    echo ""
    echo "  Z.AI API key (for GLM modes). Get one at: https://z.ai/subscribe"
    read -p "  Enter your Z.AI API key (or press Enter to skip): " ZAI_KEY
    if [ -n "$ZAI_KEY" ]; then
        echo "$ZAI_KEY" > "$CLAUDE_DIR/.zai-api-key"
        chmod 600 "$CLAUDE_DIR/.zai-api-key"
        ok "Z.AI API key saved"
    else
        warn "Skipped — GLM modes won't work without a Z.AI key"
    fi
fi

# MiniMax key
if [ -f "$CLAUDE_DIR/.minimax-api-key" ] && [ -s "$CLAUDE_DIR/.minimax-api-key" ]; then
    ok "MiniMax API key already configured"
else
    echo ""
    echo "  MiniMax API key (for MiniMax/mix modes). Get one at: https://platform.minimax.io"
    read -p "  Enter your MiniMax API key (or press Enter to skip): " MINIMAX_KEY
    if [ -n "$MINIMAX_KEY" ]; then
        echo "$MINIMAX_KEY" > "$CLAUDE_DIR/.minimax-api-key"
        chmod 600 "$CLAUDE_DIR/.minimax-api-key"
        ok "MiniMax API key saved"
    else
        warn "Skipped — MiniMax/mix modes won't work without a MiniMax key"
    fi
fi

# MiMo key
if [ -f "$CLAUDE_DIR/.mimo-api-key" ] && [ -s "$CLAUDE_DIR/.mimo-api-key" ]; then
    ok "MiMo API key already configured"
else
    echo ""
    echo "  Xiaomi MiMo API key (for MiMo modes). Get one at: https://mimo.mi.com/"
    echo "  Key format: tp-xxx (Token Plan) or sk-xxx (Pay-as-you-go)"
    read -p "  Enter your MiMo API key (or press Enter to skip): " MIMO_KEY
    if [ -n "$MIMO_KEY" ]; then
        echo "$MIMO_KEY" > "$CLAUDE_DIR/.mimo-api-key"
        chmod 600 "$CLAUDE_DIR/.mimo-api-key"
        ok "MiMo API key saved"
    else
        warn "Skipped — MiMo modes won't work without a MiMo key"
    fi
fi

echo ""

# ------------------------------------------------------------------------------
# Install Claude Code Config
# ------------------------------------------------------------------------------
info "Installing Claude Code configuration..."

mkdir -p "$CLAUDE_DIR/agents"

# Backup existing settings
if [ -f "$CLAUDE_DIR/settings.json" ]; then
    BACKUP="$CLAUDE_DIR/settings.json.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$CLAUDE_DIR/settings.json" "$BACKUP"
    ok "Existing settings backed up to $BACKUP"
fi

# Copy settings
cp "$SCRIPT_DIR/claude-config/settings.json" "$CLAUDE_DIR/settings.json"
if [ "$PLATFORM" = "linux" ]; then
    NOTIFICATION_CMD=$(play_notification)
    python3 -c "
import json
with open('$CLAUDE_DIR/settings.json', 'r') as f:
    cfg = json.load(f)
for hook_group in cfg.get('hooks', {}).get('Stop', []):
    for hook in hook_group.get('hooks', []):
        if 'afplay' in hook.get('command', ''):
            hook['command'] = '''$NOTIFICATION_CMD'''
with open('$CLAUDE_DIR/settings.json', 'w') as f:
    json.dump(cfg, f, indent=2)
" 2>/dev/null
fi
ok "settings.json installed"

# Copy statusline
cp "$SCRIPT_DIR/claude-config/statusline-command.sh" "$CLAUDE_DIR/statusline-command.sh"
chmod +x "$CLAUDE_DIR/statusline-command.sh"
ok "statusline-command.sh installed"

# Copy agents
for agent in "$SCRIPT_DIR/claude-config/agents/"*.md; do
    [ -f "$agent" ] || continue
    cp "$agent" "$CLAUDE_DIR/agents/"
done
AGENT_COUNT=$(ls "$SCRIPT_DIR/claude-config/agents/"*.md 2>/dev/null | wc -l | tr -d ' ')
ok "$AGENT_COUNT agents installed"

echo ""

# ------------------------------------------------------------------------------
# Shell Integration
# ------------------------------------------------------------------------------
info "Setting up shell integration..."

if [ -n "$ZSH_VERSION" ] || [ -f "$HOME/.zshrc" ]; then
    SHELL_CONFIG="$HOME/.zshrc"
elif [ -f "$HOME/.bashrc" ]; then
    SHELL_CONFIG="$HOME/.bashrc"
elif [ -f "$HOME/.bash_profile" ]; then
    SHELL_CONFIG="$HOME/.bash_profile"
else
    SHELL_CONFIG="$HOME/.bashrc"
    touch "$SHELL_CONFIG"
fi

# Support both old and new markers for upgrade
MARKER_OLD="# ==== CLAUDE CODE - 3-MODE ROUTING ===="
MARKER_START="# ==== CLAUDE CODE - MULTI-PROVIDER ROUTING ===="
MARKER_END="# ==== END CLAUDE CODE MULTI-PROVIDER ROUTING ===="
MARKER_END_OLD="# ==== END CLAUDE CODE 3-MODE ROUTING ===="

NEEDS_INSTALL=true
if grep -q "$MARKER_START" "$SHELL_CONFIG" 2>/dev/null; then
    warn "Shell integration already present (v5) in $SHELL_CONFIG"
    read -p "  Replace it? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        sed_inplace "/$MARKER_START/,/$MARKER_END/d" "$SHELL_CONFIG"
        rm -f "${SHELL_CONFIG}.bak"
    else
        NEEDS_INSTALL=false
    fi
elif grep -q "$MARKER_OLD" "$SHELL_CONFIG" 2>/dev/null; then
    warn "Old 3-mode shell integration found — upgrading to v5"
    sed_inplace "/$MARKER_OLD/,/$MARKER_END_OLD/d" "$SHELL_CONFIG"
    rm -f "${SHELL_CONFIG}.bak"
fi

if [ "$NEEDS_INSTALL" = true ]; then
    echo "" >> "$SHELL_CONFIG"
    cat "$SCRIPT_DIR/shell/claude-shell.sh" >> "$SHELL_CONFIG"
    ok "Shell integration added to $SHELL_CONFIG"
fi

echo ""

# ------------------------------------------------------------------------------
# Auto-start service (optional)
# ------------------------------------------------------------------------------
read -p "Install auto-start service (proxy starts on boot)? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    if [ "$PLATFORM" = "macos" ]; then
        PLIST_DIR="$HOME/Library/LaunchAgents"
        PLIST_FILE="$PLIST_DIR/com.claude-code.proxy.plist"
        mkdir -p "$PLIST_DIR"
        cp "$SCRIPT_DIR/service/com.claude-code.proxy.plist" "$PLIST_FILE"
        sed -i '' "s|VENV_PYTHON_PLACEHOLDER|$PROXY_DIR/venv/bin/python|g" "$PLIST_FILE"
        sed -i '' "s|PROXY_PY_PLACEHOLDER|$PROXY_DIR/proxy.py|g" "$PLIST_FILE"
        sed -i '' "s|PROXY_DIR_PLACEHOLDER|$PROXY_DIR|g" "$PLIST_FILE"
        launchctl load "$PLIST_FILE" 2>/dev/null
        ok "launchd service installed"
    elif [ "$PLATFORM" = "linux" ]; then
        SYSTEMD_DIR="$HOME/.config/systemd/user"
        UNIT_FILE="$SYSTEMD_DIR/claude-code-proxy.service"
        mkdir -p "$SYSTEMD_DIR"
        cp "$SCRIPT_DIR/service/claude-code-proxy.service" "$UNIT_FILE"
        sed -i "s|VENV_PYTHON_PLACEHOLDER|$PROXY_DIR/venv/bin/python|g" "$UNIT_FILE"
        sed -i "s|PROXY_PY_PLACEHOLDER|$PROXY_DIR/proxy.py|g" "$UNIT_FILE"
        sed -i "s|PROXY_DIR_PLACEHOLDER|$PROXY_DIR|g" "$UNIT_FILE"
        systemctl --user daemon-reload
        systemctl --user enable claude-code-proxy
        systemctl --user start claude-code-proxy
        ok "systemd service installed"
    fi
else
    info "Skipping auto-start (proxy starts via shell commands)"
fi

echo ""

# ------------------------------------------------------------------------------
# Test proxy
# ------------------------------------------------------------------------------
info "Testing proxy..."

PYTHONUNBUFFERED=1 "$PROXY_DIR/venv/bin/python" -u "$PROXY_DIR/proxy.py" &>/tmp/claude-proxy.log &
PROXY_PID=$!

RETRIES=0
while [ $RETRIES -lt 10 ]; do
    curl -s http://localhost:8082/health &>/dev/null && break
    sleep 1
    RETRIES=$((RETRIES + 1))
done

if kill -0 $PROXY_PID 2>/dev/null; then
    HEALTH=$(curl -s http://localhost:8082/health 2>/dev/null)
    if echo "$HEALTH" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['status'])" 2>/dev/null | grep -q "healthy"; then
        ok "Proxy is running and healthy!"
    else
        warn "Proxy started but health check failed"
    fi
    kill $PROXY_PID 2>/dev/null
else
    warn "Proxy failed to start. Check /tmp/claude-proxy.log"
fi

echo ""
echo -e "${BOLD}================================================${RESET}"
echo -e "${GREEN}${BOLD}  Installation complete!${RESET}"
echo -e "${BOLD}================================================${RESET}"
echo ""
echo "Next steps:"
echo "  1. source $SHELL_CONFIG"
echo "  2. Choose a mode:"
echo "     claude-full  → Full Claude (Anthropic OAuth)"
echo "     glm-on       → Hybrid GLM (Sonnet→GLM-5.1, Haiku→GLM-4.7)"
echo "     minimax-on   → Hybrid MiniMax (Sonnet/Haiku→MiniMax M2.7)"
echo "     mimo-on      → Hybrid MiMo (Sonnet/Haiku→MiMo-V2.5-Pro)"
echo "     mix-on       → Split (Sonnet→GLM-5.1, Haiku→MiniMax M2.7)"
echo "     glm-full     → Full GLM (all→Z.AI direct)"
echo "     mimo-full    → Full MiMo (all→Xiaomi MiMo direct)"
echo "  3. claude"
echo ""
echo "Utilities: proxy-status | proxy-tokens | proxy-keys | proxy-logs"
echo ""
