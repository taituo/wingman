#!/usr/bin/env bash
set -euo pipefail

# wingman: tmux split-screen with CLI + assistant agent + Capcom monitor
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
- Left pane: CLI (your commands)
- Right pane: Assistant agent shell (managed by Capcom)
- Second window: Capcom debug console

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
  tmux new-session -d -s "$SESSION" -n "wingman"

  # Split vertically: CLI left, Q right
  tmux split-window -h -t "$SESSION"

  # Left pane: CLI with logging and welcome
  tmux select-pane -t "$SESSION".0 -T "CLI"
  tmux send-keys -t "$SESSION".0 "script -qaf $LOG_FILE" C-m
  tmux send-keys -t "$SESSION".0 "cat <<'__WINGMAN_MENU__'" C-m
  tmux send-keys -t "$SESSION".0 "[MENU] Wingman CLI ready." C-m
  tmux send-keys -t "$SESSION".0 "[MENU] Prefix commands with '#' before typing the action." C-m
  tmux send-keys -t "$SESSION".0 "[MENU] Available actions:" C-m
  tmux send-keys -t "$SESSION".0 "[MENU]   #q <message>         -> send request to active assistant" C-m
  tmux send-keys -t "$SESSION".0 "[MENU]   #askhelp <details>  -> escalate for deep assistance" C-m
  tmux send-keys -t "$SESSION".0 "[MENU]   #askagent <details> -> request agent follow-up" C-m
  tmux send-keys -t "$SESSION".0 "[MENU]   #changeagent <name> -> switch assistant (codex/q/gemini/droid)" C-m
  tmux send-keys -t "$SESSION".0 "[MENU] Press Enter after your command to send it." C-m
  tmux send-keys -t "$SESSION".0 "__WINGMAN_MENU__" C-m

  # Right pane: Agent shell (Capcom will initialize agents)
  tmux select-pane -t "$SESSION".1 -T "Agent"
  tmux send-keys -t "$SESSION".1 "cd '$WORKSPACE'" C-m
  tmux send-keys -t "$SESSION".1 "echo 'Awaiting Capcom to launch preferred agent...'" C-m

  # Create dedicated Capcom window with debug view
  PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  tmux new-window -t "$SESSION" -n "Capcom"
  tmux send-keys -t "$SESSION":1 "cd '$PROJECT_ROOT' && WORKSPACE='$WORKSPACE' LOG_FILE='$LOG_FILE' SESSION='$SESSION' AGENT_PANE='$SESSION:0.1' ./capcom.sh" C-m
  tmux select-window -t "$SESSION":0

  echo "Wingman started: CLI | Agent"
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
