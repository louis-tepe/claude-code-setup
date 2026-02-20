#!/bin/bash
set -e

# ==============================================================================
# Claude Code Setup — Updater
# ==============================================================================
# Pulls latest changes and re-applies proxy, config, and agents
# without overwriting your .env or custom settings.
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
echo -e "${BOLD}  Claude Code Setup — Updater${RESET}"
echo -e "${BOLD}========================================${RESET}"
echo ""

# ------------------------------------------------------------------------------
# Pull latest changes
# ------------------------------------------------------------------------------
info "Pulling latest changes..."
cd "$SCRIPT_DIR"

if git pull --ff-only 2>/dev/null; then
    ok "Repository updated"
else
    warn "Could not fast-forward. Trying merge..."
    git pull || error "Failed to pull updates. Resolve conflicts manually."
fi

echo ""

# ------------------------------------------------------------------------------
# Update proxy (preserve .env)
# ------------------------------------------------------------------------------
info "Updating proxy..."

if [ ! -d "$PROXY_DIR" ]; then
    error "Proxy not installed. Run ./install.sh first."
fi

# Update proxy files (NOT .env)
cp "$SCRIPT_DIR/proxy/proxy.py" "$PROXY_DIR/"
cp "$SCRIPT_DIR/proxy/requirements.txt" "$PROXY_DIR/"
cp "$SCRIPT_DIR/proxy/start-proxy.sh" "$PROXY_DIR/"
chmod +x "$PROXY_DIR/start-proxy.sh"
ok "Proxy files updated (your .env is preserved)"

# Update dependencies
info "Updating Python dependencies..."
"$PROXY_DIR/venv/bin/pip" install -q -r "$PROXY_DIR/requirements.txt"
ok "Dependencies updated"

echo ""

# ------------------------------------------------------------------------------
# Update Claude Code config
# ------------------------------------------------------------------------------
info "Updating Claude Code configuration..."

# Backup current settings
if [ -f "$CLAUDE_DIR/settings.json" ]; then
    BACKUP="$CLAUDE_DIR/settings.json.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$CLAUDE_DIR/settings.json" "$BACKUP"
    ok "Current settings backed up to $BACKUP"
fi

# Update settings and statusline
cp "$SCRIPT_DIR/claude-config/settings.json" "$CLAUDE_DIR/settings.json"
cp "$SCRIPT_DIR/claude-config/statusline-command.sh" "$CLAUDE_DIR/statusline-command.sh"
chmod +x "$CLAUDE_DIR/statusline-command.sh"
ok "settings.json and statusline updated"

# Update agents
mkdir -p "$CLAUDE_DIR/agents"
for agent in "$SCRIPT_DIR/claude-config/agents/"*.md; do
    cp "$agent" "$CLAUDE_DIR/agents/"
done
AGENT_COUNT=$(ls "$SCRIPT_DIR/claude-config/agents/"*.md 2>/dev/null | wc -l | tr -d ' ')
ok "$AGENT_COUNT agents updated"

echo ""

# ------------------------------------------------------------------------------
# Restart proxy if running
# ------------------------------------------------------------------------------
if lsof -i:8082 -sTCP:LISTEN &>/dev/null; then
    info "Restarting proxy..."
    PROXY_PID=$(lsof -ti:8082 2>/dev/null)
    if [ -n "$PROXY_PID" ]; then
        kill $PROXY_PID 2>/dev/null
        sleep 1
    fi
    nohup "$PROXY_DIR/venv/bin/python" "$PROXY_DIR/proxy.py" &>/tmp/claude-proxy.log &
    sleep 2
    if lsof -i:8082 -sTCP:LISTEN &>/dev/null; then
        ok "Proxy restarted"
    else
        warn "Proxy failed to restart. Check /tmp/claude-proxy.log"
    fi
else
    info "Proxy not running — it will start automatically next time you run claude"
fi

echo ""
echo -e "${GREEN}${BOLD}  Update complete!${RESET}"
echo ""
