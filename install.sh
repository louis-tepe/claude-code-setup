#!/bin/bash
set -e

# ==============================================================================
# Claude Code Setup — GLM-5 Proxy + Configuration
# ==============================================================================
# This script installs:
#   1. GLM-5 proxy (routes Haiku/Sonnet → Z.AI GLM-5, Opus → Anthropic)
#   2. Claude Code global config (settings, agents, statusline, plugins)
#   3. Shell integration (auto-start proxy, aliases)
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

echo ""
echo -e "${BOLD}========================================${RESET}"
echo -e "${BOLD}  Claude Code + GLM-5 Proxy Installer${RESET}"
echo -e "${BOLD}========================================${RESET}"
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
    ok "Python 3 found ($PYTHON_VERSION)"
else
    error "Python 3 is required. Install it with: brew install python3"
fi

# pip
if python3 -m pip --version &>/dev/null; then
    ok "pip found"
else
    error "pip is required. Install it with: python3 -m ensurepip"
fi

# jq (needed for statusline)
if command -v jq &>/dev/null; then
    ok "jq found"
else
    warn "jq not found — installing with brew..."
    if command -v brew &>/dev/null; then
        brew install jq
        ok "jq installed"
    else
        error "jq is required for the statusline. Install it with: brew install jq"
    fi
fi

# Claude Code
if command -v claude &>/dev/null; then
    ok "Claude Code found"
else
    warn "Claude Code not found in PATH"
    echo "  Install it from: https://docs.anthropic.com/en/docs/claude-code"
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
    mkdir -p "$PROXY_DIR"
    cp "$SCRIPT_DIR/proxy/proxy.py" "$PROXY_DIR/"
    cp "$SCRIPT_DIR/proxy/requirements.txt" "$PROXY_DIR/"
    cp "$SCRIPT_DIR/proxy/start-proxy.sh" "$PROXY_DIR/"
    chmod +x "$PROXY_DIR/start-proxy.sh"

    # .env from example
    cp "$SCRIPT_DIR/proxy/.env.example" "$PROXY_DIR/.env"
    ok "Proxy files copied to $PROXY_DIR"

    # Create venv and install dependencies
    info "Creating Python virtual environment..."
    python3 -m venv "$PROXY_DIR/venv"
    "$PROXY_DIR/venv/bin/pip" install -q -r "$PROXY_DIR/requirements.txt"
    ok "Python dependencies installed"
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

# Copy settings
cp "$SCRIPT_DIR/claude-config/settings.json" "$CLAUDE_DIR/settings.json"
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

SHELL_CONFIG="$HOME/.zshrc"
if [ ! -f "$SHELL_CONFIG" ]; then
    SHELL_CONFIG="$HOME/.bashrc"
fi

MARKER_START="# ==== CLAUDE CODE PROXY - GLM-5 ROUTING ===="
MARKER_END="# ==== END CLAUDE CODE PROXY ===="

if grep -q "$MARKER_START" "$SHELL_CONFIG" 2>/dev/null; then
    warn "Shell integration already present in $SHELL_CONFIG"
    read -p "  Replace it? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Remove existing block
        sed -i.bak "/$MARKER_START/,/$MARKER_END/d" "$SHELL_CONFIG"
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
sleep 3

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
