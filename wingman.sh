#!/usr/bin/env bash
set -euo pipefail

# wingman: tmux session with CLI, notifications, agent eye, and Capcom monitor
HOME_DIR="${HOME:-/root}"
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
- Window 0 pane 0 (CLI): your shell with transcript logging
- Window 0 pane 1 (Notifications): tails friendly updates from Capcom
- Window 1 pane 0 (Eye): agent shell (Codex/Q/Droid on demand)
- Window 1 pane 1 (Capcom): Capcom control console

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
    WORKSPACE="$HOME_DIR/.wingman/$(date +%Y%m%d_%H%M%S)"
  fi
  mkdir -p "$WORKSPACE"
  LOG_FILE="$WORKSPACE/cli.log"
  touch "$LOG_FILE"

  PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  TMUX_ARCHIVE_ROOT="${TMUX_ARCHIVE_ROOT:-$HOME_DIR/tmux}"
  SESSION_ARCHIVE="$TMUX_ARCHIVE_ROOT/$SESSION"
  NOTIFICATION_LOG="$SESSION_ARCHIVE/notifications.log"
  mkdir -p "$SESSION_ARCHIVE"
  : >"$NOTIFICATION_LOG"

  # Create session with CLI pane
  tmux new-session -d -s "$SESSION" -n "Wingman"

  # Window 0: CLI + Notifications
  tmux select-pane -t "$SESSION":0.0 -T "CLI"
  tmux send-keys -t "$SESSION":0.0 "script -qaf $LOG_FILE" C-m

  tmux split-window -h -t "$SESSION":0
  tmux select-pane -t "$SESSION":0.1 -T "Notifications"
  tmux send-keys -t "$SESSION":0.1 "mkdir -p '$SESSION_ARCHIVE' && tail -n0 -F '$NOTIFICATION_LOG'" C-m

  # Window 1: Eye + Capcom
  tmux new-window -t "$SESSION" -n "Agents"
  tmux select-pane -t "$SESSION":1.0 -T "Eye"
  tmux send-keys -t "$SESSION":1.0 "cd '$WORKSPACE'" C-m
  tmux send-keys -t "$SESSION":1.0 "echo 'Launch Codex/Q/Droid here when needed (e.g. via tmux keybind or #capcom help codex).'" C-m

  tmux split-window -v -t "$SESSION":1
  tmux select-pane -t "$SESSION":1.1 -T "Capcom"
  tmux send-keys -t "$SESSION":1.1 "cd '$PROJECT_ROOT' && \
    WORKSPACE='$WORKSPACE' \
    LOG_FILE='$LOG_FILE' \
    SESSION='$SESSION' \
    AGENT_PANE='$SESSION:1.0' \
    NOTIFICATION_LOG='$NOTIFICATION_LOG' \
    TMUX_ARCHIVE_ROOT='$TMUX_ARCHIVE_ROOT' \
    PANE_LOGGER='$PROJECT_ROOT/pane_logger.sh' \
    ./capcom.sh" C-m
  tmux select-window -t "$SESSION":0

  echo "Wingman started: CLI | Notifications"
  echo "Workspace: $WORKSPACE"
  echo "Type '#q <message>' in CLI to forward to the active agent"

  # Auto-attach unless suppressed
  if [[ -z "${NO_ATTACH:-}" ]]; then
    tmux attach -t "$SESSION"
  else
    tmux display-message -t "$SESSION" "Wingman session ready (NO_ATTACH set)."
  fi
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
