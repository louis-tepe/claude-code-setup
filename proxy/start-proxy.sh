#!/bin/bash
# Start Claude Code Proxy - routes haiku/sonnet to GLM-5.1 via Z.AI
cd "$(dirname "$0")"
PYTHONUNBUFFERED=1 ./venv/bin/python -u proxy.py 2>&1 | tee /tmp/claude-proxy.log
