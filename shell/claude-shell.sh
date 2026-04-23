# ==== CLAUDE CODE - MULTI-PROVIDER ROUTING ====
# Modes:
#   claude-full -> Full Claude (tout -> Anthropic OAuth)
#   glm-on     -> Hybride GLM (Sonnet -> GLM-5.1, Haiku -> GLM-4.7, Opus -> Anthropic)
#   glm-full   -> Full GLM (tout -> Z.AI direct, config officielle)
#   minimax-on -> Hybride MiniMax (Sonnet/Haiku -> MiniMax M2.7, Opus -> Anthropic)
#   mix-on     -> Split (Sonnet -> MiMo-V2.5-Pro, Haiku -> MiniMax M2.7, Opus -> Anthropic)
#   mimo-on    -> Hybride MiMo (Sonnet/Haiku -> MiMo-V2.5-Pro, Opus -> Anthropic)
#   mimo-full  -> Full MiMo (tout -> Xiaomi MiMo direct, mimo-v2.5-pro)
#
# Config:
#   Mode state:    ~/.claude/proxy-routing
#   Mode env vars: ~/.claude/proxy-modes/{mode}.env
#   API keys:      ~/.claude/.*-api-key (referenced by _SHELL_*_KEY in mode files)
#   Proxy source:  ~/Documents/Code/OTHERS/claude-code-setup/proxy/proxy.py
#
# Adding a new provider:
#   1. Create ~/.claude/.newprovider-api-key
#   2. Create ~/.claude/proxy-modes/newprovider.env with _SHELL_* directives
#   3. Add a newprovider-on() command (3 lines) + proxy-status case
# ============================================================================

PROXY_ROUTING_FILE="$HOME/.claude/proxy-routing"
PROXY_MODES_DIR="$HOME/.claude/proxy-modes"
PROXY_DIR="$HOME/Documents/Code/OTHERS/claude-code-setup/proxy"
PROXY_PY="$PROXY_DIR/proxy.py"
PROXY_VENV="$PROXY_DIR/venv/bin/python"
PROXY_LOG="/tmp/claude-proxy.log"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------
_proxy_state() {
  if [ -f "$PROXY_ROUTING_FILE" ]; then
    cat "$PROXY_ROUTING_FILE" 2>/dev/null | tr -d '[:space:]'
  else
    echo "off"
  fi
}

_read_key_file() {
  local file="$HOME/.claude/$1"
  if [ -f "$file" ]; then
    cat "$file" 2>/dev/null | tr -d '[:space:]'
  else
    echo ""
  fi
}

# ---------------------------------------------------------------------------
# Proxy lifecycle — fully generic, driven by mode env files
# ---------------------------------------------------------------------------
# Mode env files support _SHELL_* directives (not passed to proxy):
#   _SHELL_SONNET_KEY=.filename     -> key file relative to ~/.claude/
#   _SHELL_HAIKU_KEY=.filename      -> key file relative to ~/.claude/
#   _SHELL_DISABLE_CACHING_SONNET=1 -> disable prompt caching for Sonnet
#   _SHELL_DISABLE_CACHING_HAIKU=1  -> disable prompt caching for Haiku
# All other lines are passed as env vars to the proxy process.
# ---------------------------------------------------------------------------
_proxy_start() {
  local mode="${1:-on}"
  local mode_env="$PROXY_MODES_DIR/${mode}.env"

  if lsof -i:8082 -sTCP:LISTEN &>/dev/null; then
    return 0
  fi

  if [ ! -f "$PROXY_PY" ]; then
    echo "ERROR: Proxy not found at $PROXY_PY"
    echo "  Run: proxy-setup"
    return 1
  fi

  if [ ! -f "$mode_env" ]; then
    echo "ERROR: Mode file not found: $mode_env"
    return 1
  fi

  local env_args=("PYTHONUNBUFFERED=1")
  local sonnet_key_file="" haiku_key_file=""

  # Parse mode env file: extract _SHELL_* directives, collect proxy env vars
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    case "$line" in
      _SHELL_SONNET_KEY=*)          sonnet_key_file="${line#*=}" ;;
      _SHELL_HAIKU_KEY=*)           haiku_key_file="${line#*=}" ;;
      _SHELL_DISABLE_CACHING_*)     ;; # handled by claude() wrapper
      *)                            env_args+=("$line") ;;
    esac
  done < "$mode_env"

  # Inject API keys from declared key files
  if [ -n "$sonnet_key_file" ]; then
    local key=$(_read_key_file "$sonnet_key_file")
    if [ -z "$key" ]; then
      echo "ERROR: API key not found at ~/.claude/$sonnet_key_file"
      return 1
    fi
    env_args+=("SONNET_PROVIDER_API_KEY=$key")
  fi
  if [ -n "$haiku_key_file" ]; then
    local key=$(_read_key_file "$haiku_key_file")
    if [ -z "$key" ]; then
      echo "ERROR: API key not found at ~/.claude/$haiku_key_file"
      return 1
    fi
    env_args+=("HAIKU_PROVIDER_API_KEY=$key")
  fi

  echo "Starting proxy ($mode)..."
  env "${env_args[@]}" nohup "$PROXY_VENV" -u "$PROXY_PY" >"$PROXY_LOG" 2>&1 &
  disown 2>/dev/null
  sleep 2
  if lsof -i:8082 -sTCP:LISTEN &>/dev/null; then
    echo "Proxy started on port 8082 ($mode)"
  else
    echo "WARNING: Proxy failed to start. Check $PROXY_LOG"
    return 1
  fi
}

_proxy_stop() {
  local pid
  pid=$(lsof -ti:8082 -sTCP:LISTEN 2>/dev/null)
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null
    # Wait for port to be released (max 5s)
    local i=0
    while lsof -i:8082 -sTCP:LISTEN &>/dev/null && [ $i -lt 10 ]; do
      sleep 0.5
      i=$((i + 1))
    done
    echo "Proxy stopped (PID $pid)"
  fi
}

_proxy_env_clean() {
  unset ANTHROPIC_BASE_URL
  unset ANTHROPIC_AUTH_TOKEN
  unset API_TIMEOUT_MS
  unset ANTHROPIC_MODEL
  unset ANTHROPIC_DEFAULT_OPUS_MODEL
  unset ANTHROPIC_DEFAULT_SONNET_MODEL
  unset ANTHROPIC_DEFAULT_HAIKU_MODEL
  unset DISABLE_PROMPT_CACHING
  unset DISABLE_PROMPT_CACHING_HAIKU
  unset DISABLE_PROMPT_CACHING_SONNET
}

_apply_caching_directives() {
  local mode_env="$PROXY_MODES_DIR/${1}.env"
  [ ! -f "$mode_env" ] && return
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in
      _SHELL_DISABLE_CACHING_SONNET=1) export DISABLE_PROMPT_CACHING_SONNET=1 ;;
      _SHELL_DISABLE_CACHING_HAIKU=1)  export DISABLE_PROMPT_CACHING_HAIKU=1 ;;
    esac
  done < "$mode_env"
}

# ---------------------------------------------------------------------------
# Z.AI MCP management (glm-full only)
# ---------------------------------------------------------------------------
_MCP_SETTINGS="$HOME/.claude.json"
_MCP_STATE_FILE="$HOME/.claude/.mcp-zai-state"

_mcp_inject_zai() {
  local key="$1"
  local s="$_MCP_SETTINGS"
  [ ! -f "$s" ] && return
  command -v jq &>/dev/null || { echo "WARNING: jq not found, skipping MCP injection"; return; }

  if [ -f "$_MCP_STATE_FILE" ] && [ "$(cat "$_MCP_STATE_FILE" 2>/dev/null)" = "active" ]; then
    return
  fi

  local tmp
  tmp=$(mktemp)
  jq --arg key "$key" '
    .mcpServers = (.mcpServers // {}) |
    .mcpServers["zai-vision"] = {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@z_ai/mcp-server"],
      "env": {"Z_AI_API_KEY": $key, "Z_AI_MODE": "ZAI"}
    } |
    .mcpServers["web-search-prime"] = {
      "type": "http",
      "url": "https://api.z.ai/api/mcp/web_search_prime/mcp",
      "headers": {"Authorization": ("Bearer " + $key)}
    } |
    .mcpServers["web-reader"] = {
      "type": "http",
      "url": "https://api.z.ai/api/mcp/web_reader/mcp",
      "headers": {"Authorization": ("Bearer " + $key)}
    }
  ' "$s" > "$tmp" 2>/dev/null
  if [ -s "$tmp" ]; then
    mv "$tmp" "$s"
    echo "active" > "$_MCP_STATE_FILE"
  else
    rm -f "$tmp"
    echo "WARNING: Failed to inject Z.AI MCPs into settings.json"
  fi
}

_mcp_remove_zai() {
  local s="$_MCP_SETTINGS"
  if [ ! -f "$_MCP_STATE_FILE" ] || [ "$(cat "$_MCP_STATE_FILE" 2>/dev/null)" != "active" ]; then
    return
  fi
  [ ! -f "$s" ] && return
  command -v jq &>/dev/null || return

  local tmp
  tmp=$(mktemp)
  jq 'del(.mcpServers["zai-vision"], .mcpServers["web-search-prime"], .mcpServers["web-reader"])' "$s" > "$tmp" 2>/dev/null
  if [ -s "$tmp" ]; then
    mv "$tmp" "$s"
  else
    rm -f "$tmp"
  fi
  rm -f "$_MCP_STATE_FILE"
}

# ---------------------------------------------------------------------------
# Main claude wrapper
# ---------------------------------------------------------------------------
claude() {
  local state
  state=$(_proxy_state)

  _proxy_env_clean
  _mcp_remove_zai

  case "$state" in
    full)
      # Direct Z.AI — no proxy
      local key=$(_read_key_file ".zai-api-key")
      if [ -z "$key" ]; then
        echo "ERROR: Z.AI API key not found at ~/.claude/.zai-api-key"
        return 1
      fi
      export ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic
      export ANTHROPIC_AUTH_TOKEN="$key"
      export API_TIMEOUT_MS=3000000
      export ANTHROPIC_DEFAULT_OPUS_MODEL=glm-5.1
      export ANTHROPIC_DEFAULT_SONNET_MODEL=glm-5.1
      export ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-4.7
      export DISABLE_PROMPT_CACHING=1
      _mcp_inject_zai "$key"
      ;;
    mimo_full)
      # Direct Xiaomi MiMo — no proxy (same model on all tiers)
      # Per official docs: https://platform.xiaomimimo.com/docs/integration/claudecode
      local key=$(_read_key_file ".mimo-api-key")
      if [ -z "$key" ]; then
        echo "ERROR: MiMo API key not found at ~/.claude/.mimo-api-key"
        return 1
      fi
      export ANTHROPIC_BASE_URL=https://token-plan-ams.xiaomimimo.com/anthropic
      export ANTHROPIC_AUTH_TOKEN="$key"
      export API_TIMEOUT_MS=3000000
      export ANTHROPIC_MODEL=mimo-v2.5-pro
      export ANTHROPIC_DEFAULT_OPUS_MODEL=mimo-v2.5-pro
      export ANTHROPIC_DEFAULT_SONNET_MODEL=mimo-v2.5-pro
      export ANTHROPIC_DEFAULT_HAIKU_MODEL=mimo-v2.5-pro
      ;;
    off)
      # Full Anthropic — nothing to configure
      ;;
    *)
      # Any proxy mode — generic handler driven by mode env file
      if ! curl -sf --max-time 2 http://localhost:8082/health >/dev/null 2>&1; then
        _proxy_stop 2>/dev/null
        _proxy_start "$state" || return 1
      fi
      export ANTHROPIC_BASE_URL=http://localhost:8082
      export API_TIMEOUT_MS=3000000
      _apply_caching_directives "$state"
      ;;
  esac

  command claude "$@"
}

# ---------------------------------------------------------------------------
# Mode switching — generic helper + named commands
# ---------------------------------------------------------------------------
_switch_mode() {
  local mode="$1"
  local mode_env="$PROXY_MODES_DIR/${mode}.env"
  if [ ! -f "$mode_env" ]; then
    echo "ERROR: Mode file not found: $mode_env"
    return 1
  fi
  _proxy_stop 2>/dev/null
  _proxy_start "$mode" || return 1
  echo "$mode" > "$PROXY_ROUTING_FILE"
  echo ""
  proxy-status
  echo "Relance 'claude' pour appliquer."
}

glm-on()     { _switch_mode on; }
minimax-on() { _switch_mode minimax; }
mix-on()     { _switch_mode mix; }
mimo-on()    { _switch_mode mimo; }

glm-full() {
  local key=$(_read_key_file ".zai-api-key")
  if [ -z "$key" ]; then
    echo "ERROR: Z.AI API key not found at ~/.claude/.zai-api-key"
    return 1
  fi
  echo "full" > "$PROXY_ROUTING_FILE"
  _proxy_stop
  echo ""
  echo "Mode FULL GLM active"
  echo "  Tout -> Z.AI direct (config officielle)"
  echo ""
  echo "Relance 'claude' pour appliquer."
}

mimo-full() {
  local key=$(_read_key_file ".mimo-api-key")
  if [ -z "$key" ]; then
    echo "ERROR: MiMo API key not found at ~/.claude/.mimo-api-key"
    return 1
  fi
  echo "mimo_full" > "$PROXY_ROUTING_FILE"
  _proxy_stop
  echo ""
  echo "Mode FULL MIMO active"
  echo "  Tout -> Xiaomi MiMo direct (token-plan-ams.xiaomimimo.com)"
  echo "  Models: opus/sonnet/haiku = mimo-v2.5-pro"
  echo ""
  echo "Relance 'claude' pour appliquer."
}

claude-full() {
  echo "off" > "$PROXY_ROUTING_FILE"
  _proxy_stop
  echo ""
  echo "Mode FULL CLAUDE active"
  echo "  Tout -> Anthropic OAuth"
  echo ""
  echo "Relance 'claude' pour appliquer."
}

# ---------------------------------------------------------------------------
# Utility commands
# ---------------------------------------------------------------------------
proxy-status() {
  local state
  state=$(_proxy_state)
  local proxy_running="no"
  if lsof -i:8082 -sTCP:LISTEN &>/dev/null; then
    proxy_running="yes"
  fi

  echo ""
  case "$state" in
    on)
      echo "  Mode:    HYBRIDE GLM"
      echo "  Sonnet -> Z.AI GLM-5.1  (proxy :8082)"
      echo "  Haiku  -> Z.AI GLM-4.7  (proxy :8082)"
      echo "  Opus   -> Anthropic OAuth"
      echo "  Caching: disabled"
      ;;
    minimax)
      echo "  Mode:    HYBRIDE MINIMAX"
      echo "  Sonnet/Haiku -> MiniMax M2.7 (proxy :8082)"
      echo "  Opus         -> Anthropic OAuth"
      echo "  Caching: active"
      ;;
    mix)
      echo "  Mode:    SPLIT GLOBAL (MiMo + MiniMax)"
      echo "  Sonnet -> Xiaomi MiMo-V2.5-Pro  (intelligence, caching active)"
      echo "  Haiku  -> MiniMax M2.7          (vitesse, caching active)"
      echo "  Opus   -> Anthropic OAuth"
      ;;
    mimo)
      echo "  Mode:    HYBRIDE MIMO"
      echo "  Sonnet/Haiku -> Xiaomi MiMo-V2.5-Pro (proxy :8082)"
      echo "  Opus         -> Anthropic OAuth"
      echo "  Caching: active"
      ;;
    full)
      echo "  Mode:    FULL GLM"
      echo "  Tout -> Z.AI direct (https://api.z.ai/api/anthropic)"
      echo "  Models: opus/sonnet=glm-5.1, haiku=glm-4.7"
      echo "  Caching: disabled"
      ;;
    mimo_full)
      echo "  Mode:    FULL MIMO"
      echo "  Tout -> Xiaomi MiMo direct (https://token-plan-ams.xiaomimimo.com/anthropic)"
      echo "  Models: opus/sonnet/haiku = mimo-v2.5-pro"
      echo "  Caching: active"
      ;;
    off)
      echo "  Mode:    FULL CLAUDE"
      echo "  Tout -> Anthropic OAuth"
      ;;
    *)
      echo "  Mode:    $state (custom)"
      echo "  Config:  $PROXY_MODES_DIR/${state}.env"
      ;;
  esac
  echo "  Proxy:   $proxy_running"
  echo "  Config:  $PROXY_ROUTING_FILE ($state)"

  # Show MCP status for glm-full
  if [ "$state" = "full" ]; then
    local mcp_active="no"
    if [ -f "$_MCP_SETTINGS" ]; then
      local has_zai
      has_zai=$(jq '.mcpServers | has("zai-vision") // false' "$_MCP_SETTINGS" 2>/dev/null)
      [ "$has_zai" = "true" ] && mcp_active="yes"
    fi
    echo "  MCPs:    $mcp_active (zai-vision, web-search-prime, web-reader)"
  fi

  # Show key files referenced by current mode (deduplicated)
  local mode_env="$PROXY_MODES_DIR/${state}.env"
  if [ -f "$mode_env" ]; then
    local _shown_keys=""
    while IFS= read -r line; do
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      case "$line" in
        _SHELL_SONNET_KEY=*|_SHELL_HAIKU_KEY=*)
          local key_file="${line#*=}"
          # Skip if already shown
          case "$_shown_keys" in *"$key_file"*) continue ;; esac
          _shown_keys="$_shown_keys $key_file"
          local key=$(_read_key_file "$key_file")
          local label="${key_file#.}"
          label="${label%-api-key}"
          if [ -n "$key" ]; then
            echo "  ${label}:$(printf '%*s' $((10 - ${#label})) '') ~/.claude/$key_file (${#key} chars)"
          else
            echo "  ${label}:$(printf '%*s' $((10 - ${#label})) '') NOT FOUND — echo 'key' > ~/.claude/$key_file"
          fi
          ;;
      esac
    done < "$mode_env"
  fi

  # Health check when proxy is running
  if [ "$proxy_running" = "yes" ]; then
    local health
    health=$(curl -s --max-time 2 http://localhost:8082/health 2>/dev/null)
    if [ -n "$health" ]; then
      local cb_haiku cb_sonnet reqs fallbacks
      cb_haiku=$(echo "$health" | jq -r '.circuit_breaker.haiku // "?"' 2>/dev/null)
      cb_sonnet=$(echo "$health" | jq -r '.circuit_breaker.sonnet // "?"' 2>/dev/null)
      reqs=$(echo "$health" | jq -r '.stats.total_requests // 0' 2>/dev/null)
      fallbacks=$(echo "$health" | jq -r '.stats.fallbacks_to_anthropic // 0' 2>/dev/null)
      echo ""
      echo "  Health:"
      echo "    Requests:  $reqs (fallbacks: $fallbacks)"
      echo "    Haiku CB:  $cb_haiku"
      echo "    Sonnet CB: $cb_sonnet"
    else
      echo ""
      echo "  Health: unreachable (proxy may be degraded)"
    fi
  fi
  echo ""
}

proxy-tokens() {
  local state=$(_proxy_state)
  if [ "$state" = "off" ] || [ "$state" = "full" ] || [ "$state" = "mimo_full" ]; then
    echo "Disponible uniquement en mode proxy (actuel: $state)"
    return 1
  fi
  if ! lsof -i:8082 -sTCP:LISTEN &>/dev/null; then
    echo "Proxy not running."
    return 1
  fi
  curl -s http://localhost:8082/stats/tokens | python3 -m json.tool
}

proxy-keys() {
  echo "API keys in ~/.claude/:"
  for f in "$HOME/.claude"/.*-api-key; do
    [ -f "$f" ] || continue
    local name=$(basename "$f")
    local key=$(cat "$f" 2>/dev/null | tr -d '[:space:]')
    local label="${name#.}"
    label="${label%-api-key}"
    [ -n "$key" ] && echo "  $label: configured (${#key} chars)" || echo "  $label: EMPTY"
  done
}

proxy-setup() {
  echo "Setting up proxy at $PROXY_DIR..."
  if [ -d "$PROXY_DIR" ] && [ -f "$PROXY_PY" ]; then
    echo "  Already exists. Use proxy-status to check."
    if [ ! -d "$PROXY_DIR/venv" ]; then
      echo "  Missing venv. Run:"
      echo "    cd $PROXY_DIR && python3 -m venv venv && ./venv/bin/pip install -q -r requirements.txt"
    fi
    return 0
  fi
  echo "  Source repo not found. Clone it first:"
  echo "    git clone git@github.com:louis-tepe/claude-code-setup.git ~/Documents/Code/OTHERS/claude-code-setup"
  echo "    cd ~/Documents/Code/OTHERS/claude-code-setup/proxy"
  echo "    python3 -m venv venv && ./venv/bin/pip install -q -r requirements.txt"
  echo "    cp .env.example .env  # operational config only (port, log level)"
}

# ---------------------------------------------------------------------------
# Aliases
# ---------------------------------------------------------------------------
# Backward compat (glm-* -> proxy-* / claude-full)
glm-off() { claude-full; }
alias glm-status='proxy-status'
alias glm-tokens='proxy-tokens'
alias glm-key='proxy-keys'
alias glm-setup='proxy-setup'
alias glm-logs='proxy-logs'

alias cc='claude --dangerously-skip-permissions'
alias proxy-logs='tail -f /tmp/claude-proxy.log'
# ==== END CLAUDE CODE MULTI-PROVIDER ROUTING ====
