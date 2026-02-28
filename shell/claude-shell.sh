# ==== CLAUDE CODE PROXY - GLM-5 ROUTING ====
# Source this file in your .zshrc or .bashrc:
#   source ~/claude-code-proxy/claude-shell.sh
# Or the install script adds it automatically.

GLM_ROUTING_FILE="$HOME/.claude/glm-routing"
GLM_PROXY_PY="$HOME/Documents/Code/Project/claude-code-setup/proxy/proxy.py"
GLM_PROXY_VENV="$HOME/Documents/Code/Project/claude-code-setup/proxy/venv/bin/python"
GLM_PROXY_LOG="/tmp/claude-proxy.log"

# Read current routing state (default: on)
_glm_state() {
  if [ -f "$GLM_ROUTING_FILE" ]; then
    cat "$GLM_ROUTING_FILE" 2>/dev/null | tr -d '[:space:]'
  else
    echo "on"
  fi
}

# Start the proxy if not running
_glm_proxy_start() {
  if ! lsof -i:8082 -sTCP:LISTEN &>/dev/null; then
    echo "Starting GLM-5 proxy..."
    nohup "$GLM_PROXY_VENV" "$GLM_PROXY_PY" >"$GLM_PROXY_LOG" 2>&1 &
    sleep 2
    if lsof -i:8082 -sTCP:LISTEN &>/dev/null; then
      echo "Proxy started on port 8082"
    else
      echo "WARNING: Proxy failed to start. Check $GLM_PROXY_LOG"
      return 1
    fi
  fi
}

# Stop the proxy if running
_glm_proxy_stop() {
  local pid
  pid=$(lsof -ti:8082 -sTCP:LISTEN 2>/dev/null)
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null
    echo "Proxy stopped (PID $pid)"
  fi
}

# Main claude wrapper — configures env based on routing state
claude() {
  local state
  state=$(_glm_state)

  if [ "$state" = "on" ]; then
    _glm_proxy_start || return 1
    export ANTHROPIC_BASE_URL=http://localhost:8082
    export DISABLE_PROMPT_CACHING_HAIKU=1
    export DISABLE_PROMPT_CACHING_SONNET=1
  else
    unset ANTHROPIC_BASE_URL
    unset DISABLE_PROMPT_CACHING_HAIKU
    unset DISABLE_PROMPT_CACHING_SONNET
  fi

  command claude "$@"
}

# Toggle commands
glm-on() {
  echo "on" > "$GLM_ROUTING_FILE"
  _glm_proxy_start
  echo "GLM-5 routing ENABLED. Relance claude pour appliquer."
}

glm-off() {
  echo "off" > "$GLM_ROUTING_FILE"
  _glm_proxy_stop
  echo "Direct Anthropic mode. Relance claude pour appliquer."
}

glm-status() {
  local state
  state=$(_glm_state)
  local proxy_running="no"
  if lsof -i:8082 -sTCP:LISTEN &>/dev/null; then
    proxy_running="yes"
  fi

  if [ "$state" = "on" ]; then
    echo "Routing:  GLM-5 (Sonnet/Haiku → Z.AI, Opus → Anthropic)"
  else
    echo "Routing:  DIRECT (tout → Anthropic)"
  fi
  echo "Proxy:    $proxy_running"
  echo "State:    $GLM_ROUTING_FILE ($state)"
}

# Token usage stats
glm-tokens() {
  if ! lsof -i:8082 -sTCP:LISTEN &>/dev/null; then
    echo "Proxy not running."
    return 1
  fi
  curl -s http://localhost:8082/stats/tokens | python3 -m json.tool
}

# Aliases
alias cc='claude --dangerously-skip-permissions'
alias glm-logs='tail -f /tmp/claude-proxy.log'
# ==== END CLAUDE CODE PROXY ====
