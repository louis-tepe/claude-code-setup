#!/bin/bash
# Start Claude Code Proxy - routes haiku/sonnet to GLM-5 via Z.AI
cd "$(dirname "$0")"
./venv/bin/python proxy.py 2>&1 | tee /tmp/claude-proxy.log
