#!/usr/bin/env bash
set -euo pipefail

# wingman: tmux session with CLI, discussion agent, and Capcom monitor
SESSION="${SESSION:-wingman}"
WORKSPACE="${WORKSPACE:-}"
LOG_FILE="${LOG_FILE:-}"

# Check if called without proper environment
if [[ -z "$SESSION" || -z "$WORKSPACE" ]]; then
  echo "You probably want to start ./fly.sh instead"
  exit 1
fi

usage() {
  cat <<EOF
Usage: $0 [start|stop|status]

Creates tmux session with:
- Window 0 pane 0: CLI (your commands + logging)
- Window 0 pane 1: Discussion agent shell (managed by Capcom)
- Window 1: Capcom debug console

Use hashtags in CLI (e.g. "#q analyze this error") to forward context to the active agent.
EOF
}

session_exists() {
  tmux has-session -t "$SESSION" 2>/dev/null
}

start_session() {
  if session_exists; then
    echo "Session '$SESSION' exists. Attaching..."
    tmux attach -t "$SESSION"
    exit 0
  fi

  # Use workspace from environment or create default
  if [[ -z "$WORKSPACE" ]]; then
    WORKSPACE="$HOME/.wingman/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$WORKSPACE"
  fi
  LOG_FILE="$WORKSPACE/cli.log"
  touch "$LOG_FILE"

  # Create session with CLI pane
  tmux new-session -d -s "$SESSION" -n "Wingman"

  # CLI pane with logging (left)
  tmux select-pane -t "$SESSION":0.0 -T "CLI"
  tmux send-keys -t "$SESSION":0.0 "script -qaf $LOG_FILE" C-m

  # Discussion pane (right) for agent responses
  tmux split-window -h -t "$SESSION":0
  tmux select-pane -t "$SESSION":0.1 -T "Discussion"
  tmux send-keys -t "$SESSION":0.1 "cd '$WORKSPACE'" C-m
  tmux send-keys -t "$SESSION":0.1 "echo 'Discussion agent pane ready for Capcom.'" C-m

  # Create dedicated Capcom window with debug view
  PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  tmux new-window -t "$SESSION" -n "Capcom"
  tmux send-keys -t "$SESSION":1 "cd '$PROJECT_ROOT' && WORKSPACE='$WORKSPACE' LOG_FILE='$LOG_FILE' SESSION='$SESSION' AGENT_PANE='$SESSION:0.1' ./capcom.sh" C-m
  tmux select-window -t "$SESSION":0

  echo "Wingman started: CLI | Discussion"
  echo "Workspace: $WORKSPACE"
  echo "Type '#q <message>' in CLI to forward to the active agent"

  # Auto-attach to the session
  tmux attach -t "$SESSION"
}

stop_session() {
  # Kill monitor
  if [[ -f "/tmp/wingman_monitor_$SESSION.pid" ]]; then
    kill "$(cat "/tmp/wingman_monitor_$SESSION.pid")" 2>/dev/null || true
    rm -f "/tmp/wingman_monitor_$SESSION.pid"
  fi

  # Kill tmux session
  if session_exists; then
    tmux kill-session -t "$SESSION"
  echo "Wingman stopped"
  else
    echo "Session not running"
  fi
}



case "${1:-}" in
  stop) stop_session ;;
  status)
    if session_exists; then
  echo "Wingman running (session: $SESSION)"
    else
  echo "Wingman not running"
    fi
    ;;


  ""|start) start_session ;;
  *) usage; exit 1 ;;
esac
