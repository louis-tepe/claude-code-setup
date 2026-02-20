#!/bin/bash

# ==============================================================================
# Claude Code Setup — Uninstaller
# ==============================================================================
# Removes proxy, config, shell integration, and auto-start service.
# ==============================================================================

BOLD="\033[1m"
GREEN="\033[92m"
YELLOW="\033[93m"
RED="\033[91m"
CYAN="\033[96m"
RESET="\033[0m"

PROXY_DIR="$HOME/claude-code-proxy"
CLAUDE_DIR="$HOME/.claude"
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/com.claude-code.proxy.plist"
SYSTEMD_UNIT="$HOME/.config/systemd/user/claude-code-proxy.service"

info()  { echo -e "${CYAN}[INFO]${RESET} $1"; }
ok()    { echo -e "${GREEN}[OK]${RESET} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $1"; }

OS="$(uname -s)"
case "$OS" in
    Darwin) PLATFORM="macos" ;;
    Linux)  PLATFORM="linux" ;;
    *)      PLATFORM="unknown" ;;
esac

echo ""
echo -e "${BOLD}========================================${RESET}"
echo -e "${BOLD}  Claude Code Setup — Uninstaller${RESET}"
echo -e "${BOLD}========================================${RESET}"
echo ""
echo -e "${YELLOW}This will remove:${RESET}"
echo "  - GLM-5 proxy ($PROXY_DIR)"
echo "  - Claude Code custom agents (~/.claude/agents/)"
echo "  - Shell integration from ~/.zshrc or ~/.bashrc"
echo "  - Auto-start service (if installed)"
echo ""
echo -e "${YELLOW}This will NOT remove:${RESET}"
echo "  - Claude Code itself"
echo "  - Your Claude Code settings (a backup will be restored if available)"
echo ""
read -p "Continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

echo ""

# ------------------------------------------------------------------------------
# Stop proxy
# ------------------------------------------------------------------------------
if lsof -i:8082 -sTCP:LISTEN &>/dev/null; then
    info "Stopping proxy..."
    PROXY_PID=$(lsof -ti:8082 2>/dev/null)
    if [ -n "$PROXY_PID" ]; then
        kill $PROXY_PID 2>/dev/null
        ok "Proxy stopped"
    fi
fi

# ------------------------------------------------------------------------------
# Remove auto-start service
# ------------------------------------------------------------------------------
if [ "$PLATFORM" = "macos" ] && [ -f "$LAUNCHD_PLIST" ]; then
    info "Removing launchd service..."
    launchctl unload "$LAUNCHD_PLIST" 2>/dev/null
    rm -f "$LAUNCHD_PLIST"
    ok "launchd service removed"
elif [ "$PLATFORM" = "linux" ] && [ -f "$SYSTEMD_UNIT" ]; then
    info "Removing systemd service..."
    systemctl --user stop claude-code-proxy 2>/dev/null
    systemctl --user disable claude-code-proxy 2>/dev/null
    rm -f "$SYSTEMD_UNIT"
    systemctl --user daemon-reload 2>/dev/null
    ok "systemd service removed"
fi

# ------------------------------------------------------------------------------
# Remove proxy
# ------------------------------------------------------------------------------
if [ -d "$PROXY_DIR" ]; then
    info "Removing proxy..."
    rm -rf "$PROXY_DIR"
    ok "Proxy removed"
else
    info "Proxy directory not found — already removed"
fi

# ------------------------------------------------------------------------------
# Remove shell integration
# ------------------------------------------------------------------------------
MARKER_START="# ==== CLAUDE CODE PROXY - GLM-5 ROUTING ===="
MARKER_END="# ==== END CLAUDE CODE PROXY ===="

for RC_FILE in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
    if [ -f "$RC_FILE" ] && grep -q "$MARKER_START" "$RC_FILE" 2>/dev/null; then
        info "Removing shell integration from $RC_FILE..."
        if [ "$PLATFORM" = "macos" ]; then
            sed -i '' "/$MARKER_START/,/$MARKER_END/d" "$RC_FILE"
        else
            sed -i "/$MARKER_START/,/$MARKER_END/d" "$RC_FILE"
        fi
        ok "Shell integration removed from $RC_FILE"
    fi
done

# ------------------------------------------------------------------------------
# Remove agents
# ------------------------------------------------------------------------------
AGENTS=("Bash.md" "Explore.md" "Plan.md" "claude-code-guide.md" "general-purpose.md" "magic-docs.md" "statusline-setup.md")
info "Removing custom agents..."
for agent in "${AGENTS[@]}"; do
    rm -f "$CLAUDE_DIR/agents/$agent"
done
ok "Custom agents removed"

# ------------------------------------------------------------------------------
# Restore settings backup
# ------------------------------------------------------------------------------
LATEST_BACKUP=$(ls -t "$CLAUDE_DIR"/settings.json.backup.* 2>/dev/null | head -1)
if [ -n "$LATEST_BACKUP" ]; then
    read -p "Restore settings from backup ($LATEST_BACKUP)? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        cp "$LATEST_BACKUP" "$CLAUDE_DIR/settings.json"
        ok "Settings restored from backup"
    fi
fi

# Remove statusline
rm -f "$CLAUDE_DIR/statusline-command.sh"

# Clean up log
rm -f /tmp/claude-proxy.log

echo ""
echo -e "${GREEN}${BOLD}  Uninstallation complete!${RESET}"
echo ""
echo "Don't forget to reload your shell: source ~/.zshrc"
echo ""
