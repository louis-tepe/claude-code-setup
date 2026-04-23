#!/bin/bash
# Status line script for Claude Code
# Displays: model | context usage | project & directory

input=$(cat)

# Model
model=$(echo "$input" | jq -r '.model.display_name // "?"')
model_id=$(echo "$input" | jq -r '.model.id // ""')

# Context window
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0')
ctx_size=$(echo "$input" | jq -r '.context_window.context_window_size // 0')
used_pct_int=$(printf "%.0f" "$used_pct" 2>/dev/null || echo "0")
ctx_k=$(( ctx_size / 1000 ))

# Context bar (10 chars wide)
filled=$(( used_pct_int / 10 ))
empty=$(( 10 - filled ))
bar=$(printf '%0.s#' $(seq 1 $filled 2>/dev/null) || true)
bar="${bar}$(printf '%0.s-' $(seq 1 $empty 2>/dev/null) || true)"

# Workspace
cwd=$(echo "$input" | jq -r '.workspace.current_dir // ""')
project_dir=$(echo "$input" | jq -r '.workspace.project_dir // ""')

if [ -n "$project_dir" ] && [ "$project_dir" != "null" ]; then
    project_name=$(basename "$project_dir")
else
    project_name=""
fi

if [[ "$cwd" == "$HOME"* ]]; then
    display_path="~${cwd#$HOME}"
else
    display_path="$cwd"
fi

# Cost
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
cost_fmt=$(printf "$%.4f" "$cost" 2>/dev/null || echo "\$0.00")

# Routing state
routing_file="$HOME/.claude/proxy-routing"
if [ -f "$routing_file" ]; then
    routing_state=$(cat "$routing_file" 2>/dev/null | tr -d '[:space:]')
    case "$routing_state" in
        off)       routing_label="CLAUDE" ;;
        full)      routing_label="GLM-FULL" ;;
        on)        routing_label="GLM" ;;
        minimax)   routing_label="MINIMAX" ;;
        mix)       routing_label="MIX" ;;
        mimo)      routing_label="MIMO" ;;
        mimo_full) routing_label="MIMO-FULL" ;;
        *)         routing_label="$routing_state" ;;
    esac
else
    routing_label="CLAUDE"
fi

# Build output
parts=""
parts="${parts}${model}"
parts="${parts} | ctx [${bar}] ${used_pct_int}% of ${ctx_k}k"
parts="${parts} | ${cost_fmt}"
parts="${parts} | ${routing_label}"

if [ -n "$project_name" ]; then
    parts="${parts} | ${project_name}: ${display_path}"
else
    parts="${parts} | ${display_path}"
fi

printf "%s" "$parts"
