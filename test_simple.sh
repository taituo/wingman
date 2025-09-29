#!/usr/bin/env bash
set -euo pipefail

# Simple test to verify the basic flow works

echo "Testing wingman components..."

# Test 1: Check if scripts exist and are executable
for script in fly.sh wingman.sh capcom.sh; do
  if [[ -x "./$script" ]]; then
    echo "✓ $script exists and is executable"
  else
    echo "✗ $script missing or not executable"
    exit 1
  fi
done

# Test 2: Check dependencies
if ! command -v tmux >/dev/null; then
  echo "✗ tmux not found"
  exit 1
fi
echo "✓ tmux available"

if ! command -v q >/dev/null; then
  echo "✗ Amazon Q CLI not found"
  exit 1
fi
echo "✓ Amazon Q CLI available"

echo "All basic checks passed. Try ./fly.sh to test full flow."
