#!/bin/bash
set -e

# ==============================================================================
# Claude Code Setup — GLM-5 Proxy + Configuration
# ==============================================================================
# This script installs:
#   1. GLM-5 proxy (routes Haiku/Sonnet → Z.AI GLM-5, Opus → Anthropic)
#   2. Claude Code global config (settings, agents, statusline, plugins)
#   3. Shell integration (auto-start proxy, aliases)
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

# Cross-platform sed -i
sed_inplace() {
    if [ "$PLATFORM" = "macos" ]; then
        sed -i.bak "$@"
    else
        sed -i "$@"
    fi
}

# Cross-platform notification sound
play_notification() {
    if [ "$PLATFORM" = "macos" ]; then
        echo 'afplay /System/Library/Sounds/Glass.aiff &'
    else
        # Linux: use paplay if available, otherwise no-op
        echo '(command -v paplay &>/dev/null && paplay /usr/share/sounds/freedesktop/stereo/complete.oga &) 2>/dev/null || true'
    fi
}

echo ""
echo -e "${BOLD}========================================${RESET}"
echo -e "${BOLD}  Claude Code + GLM-5 Proxy Installer${RESET}"
echo -e "${BOLD}========================================${RESET}"
echo ""
echo "Platform: $PLATFORM"
echo ""
echo "This will install:"
echo "  - GLM-5 proxy (Haiku/Sonnet → Z.AI, Opus → Anthropic)"
echo "  - Claude Code config (agents, plugins, statusline)"
echo "  - Shell integration (auto-start proxy)"
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

# jq (needed for statusline)
if command -v jq &>/dev/null; then
    ok "jq found"
else
    warn "jq not found — installing..."
    if [ "$PLATFORM" = "macos" ]; then
        if command -v brew &>/dev/null; then
            brew install jq
            ok "jq installed"
        else
            error "jq is required. Install Homebrew (brew.sh) then: brew install jq"
        fi
    else
        if command -v apt &>/dev/null; then
            sudo apt install -y jq
            ok "jq installed"
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y jq
            ok "jq installed"
        else
            error "jq is required. Install it with your package manager."
        fi
    fi
fi

# Claude Code
if command -v claude &>/dev/null; then
    ok "Claude Code found"
else
    warn "Claude Code not found in PATH"
    echo "  Install it with: npm install -g @anthropic-ai/claude-code"
    echo "  The proxy and config will still be installed."
fi

echo ""

# ------------------------------------------------------------------------------
# Install Proxy
# ------------------------------------------------------------------------------
info "Installing GLM-5 proxy..."

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
    mkdir -p "$PROXY_DIR" || error "Failed to create $PROXY_DIR"
    cp "$SCRIPT_DIR/proxy/proxy.py" "$PROXY_DIR/" || error "Failed to copy proxy.py"
    cp "$SCRIPT_DIR/proxy/requirements.txt" "$PROXY_DIR/" || error "Failed to copy requirements.txt"
    cp "$SCRIPT_DIR/proxy/start-proxy.sh" "$PROXY_DIR/" || error "Failed to copy start-proxy.sh"
    chmod +x "$PROXY_DIR/start-proxy.sh"

    # .env from example
    cp "$SCRIPT_DIR/proxy/.env.example" "$PROXY_DIR/.env"
    ok "Proxy files copied to $PROXY_DIR"

    # Create venv and install dependencies
    info "Creating Python virtual environment..."
    python3 -m venv "$PROXY_DIR/venv" || error "Failed to create venv. On Linux, you may need: sudo apt install python3-venv"
    "$PROXY_DIR/venv/bin/pip" install -q -r "$PROXY_DIR/requirements.txt" || error "Failed to install Python dependencies"
    ok "Python dependencies installed"
    CLEANUP_PROXY=false
fi

echo ""

# ------------------------------------------------------------------------------
# Install Claude Code Config
# ------------------------------------------------------------------------------
info "Installing Claude Code configuration..."

# Backup existing settings
if [ -f "$CLAUDE_DIR/settings.json" ]; then
    BACKUP="$CLAUDE_DIR/settings.json.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$CLAUDE_DIR/settings.json" "$BACKUP"
    ok "Existing settings backed up to $BACKUP"
fi

# Create directories
mkdir -p "$CLAUDE_DIR/agents"

# Copy settings — adapt notification sound for platform
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
    cp "$agent" "$CLAUDE_DIR/agents/"
done
AGENT_COUNT=$(ls "$SCRIPT_DIR/claude-config/agents/"*.md 2>/dev/null | wc -l | tr -d ' ')
ok "$AGENT_COUNT agents installed"

echo ""

# ------------------------------------------------------------------------------
# Shell Integration
# ------------------------------------------------------------------------------
info "Setting up shell integration..."

# Detect shell config file
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

MARKER_START="# ==== CLAUDE CODE PROXY - GLM-5 ROUTING ===="
MARKER_END="# ==== END CLAUDE CODE PROXY ===="

if grep -q "$MARKER_START" "$SHELL_CONFIG" 2>/dev/null; then
    warn "Shell integration already present in $SHELL_CONFIG"
    read -p "  Replace it? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Remove existing block
        sed_inplace "/$MARKER_START/,/$MARKER_END/d" "$SHELL_CONFIG"
        rm -f "${SHELL_CONFIG}.bak"
        # Append new block
        echo "" >> "$SHELL_CONFIG"
        cat "$SCRIPT_DIR/shell/claude-shell.sh" >> "$SHELL_CONFIG"
        ok "Shell integration replaced in $SHELL_CONFIG"
    else
        info "Skipping shell integration"
    fi
else
    echo "" >> "$SHELL_CONFIG"
    cat "$SCRIPT_DIR/shell/claude-shell.sh" >> "$SHELL_CONFIG"
    ok "Shell integration added to $SHELL_CONFIG"
fi

echo ""

# ------------------------------------------------------------------------------
# Plugins
# ------------------------------------------------------------------------------
info "Plugins to install (run these commands manually):"
echo ""
echo "  claude plugins:install feature-dev@claude-plugins-official"
echo "  claude plugins:install code-review@claude-plugins-official"
echo "  claude plugins:install commit-commands@claude-plugins-official"
echo "  claude plugins:install security-guidance@claude-plugins-official"
echo "  claude plugins:install hookify@claude-plugins-official"
echo "  claude plugins:install frontend-design@claude-plugins-official"
echo ""

# ------------------------------------------------------------------------------
# Test
# ------------------------------------------------------------------------------
info "Testing proxy..."

# Start proxy in background
"$PROXY_DIR/venv/bin/python" "$PROXY_DIR/proxy.py" &>/tmp/claude-proxy.log &
PROXY_PID=$!

# Wait up to 10 seconds for proxy to be ready
RETRIES=0
MAX_WAIT=10
while [ $RETRIES -lt $MAX_WAIT ]; do
    if curl -s http://localhost:8082/health &>/dev/null; then
        break
    fi
    sleep 1
    RETRIES=$((RETRIES + 1))
done

if kill -0 $PROXY_PID 2>/dev/null; then
    # Check health
    HEALTH=$(curl -s http://localhost:8082/health 2>/dev/null)
    if echo "$HEALTH" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['status'])" 2>/dev/null | grep -q "healthy"; then
        ok "Proxy is running and healthy!"
        echo ""
        echo "  Routing:"
        echo "$HEALTH" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for tier, dest in d['routing'].items():
    print(f'    {tier:>8s} → {dest}')
" 2>/dev/null
    else
        warn "Proxy started but health check failed"
    fi
    # Stop test proxy
    kill $PROXY_PID 2>/dev/null
else
    warn "Proxy failed to start. Check /tmp/claude-proxy.log"
fi

echo ""
echo -e "${BOLD}========================================${RESET}"
echo -e "${GREEN}${BOLD}  Installation complete!${RESET}"
echo -e "${BOLD}========================================${RESET}"
echo ""
echo "Next steps:"
echo "  1. Run: source $SHELL_CONFIG"
echo "  2. Run: claude"
echo "     (The proxy starts automatically)"
echo "  3. Check logs: tail -f /tmp/claude-proxy.log"
echo ""
echo "Requirements:"
echo "  - Claude Max subscription (for Opus 4.6 as main agent)"
echo "  - Be logged in: claude login"
echo ""
