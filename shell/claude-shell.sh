# ==== CLAUDE CODE PROXY - GLM-5 ROUTING ====
# Source this file in your .zshrc or .bashrc:
#   source ~/claude-code-proxy/claude-shell.sh
# Or the install script adds it automatically.

export ANTHROPIC_BASE_URL=http://localhost:8082

# Auto-start proxy when using claude
claude() {
  if ! lsof -i:8082 -sTCP:LISTEN &>/dev/null; then
    echo "Starting GLM-5 proxy..."
    nohup ~/claude-code-proxy/venv/bin/python ~/claude-code-proxy/proxy.py &>/tmp/claude-proxy.log &
    sleep 2
    if lsof -i:8082 -sTCP:LISTEN &>/dev/null; then
      echo "Proxy started on port 8082"
    else
      echo "WARNING: Proxy failed to start. Check /tmp/claude-proxy.log"
      return 1
    fi
  fi
  command claude "$@"
}

# Aliases
alias cc='claude code --dangerously-skip-permissions'
# ==== END CLAUDE CODE PROXY ====
