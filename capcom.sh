#!/usr/bin/env bash
set -euo pipefail

# capcom: monitors CLI logs and orchestrates assistant agents
WORKSPACE="${WORKSPACE:-}"
LOG_FILE="${LOG_FILE:-}"
SESSION="${SESSION:-}"
AGENT_PANE="${AGENT_PANE:-${SESSION}:0.1}"
ACTIVITY_LOG="$WORKSPACE/capcom.log"
LAST_LINE_FILE="$WORKSPACE/.capcom_last_line"

if [[ -z "$WORKSPACE" || -z "$LOG_FILE" || -z "$SESSION" ]]; then
  echo "You probably want to start ./fly.sh instead"
  exit 1
fi

declare -A AGENT_COMMANDS=(
  [codex]="codex chat"
  [q]="q chat"
  [gemini]="gemini chat"
  [droid]="droid chat"
)

CODEX_SANDBOX_MODE="${CODEX_SANDBOX:-workspace-write}"
PRIORITY_AGENTS=(codex q gemini droid)
AVAILABLE_AGENTS=()
CURRENT_AGENT=""
DEFAULT_AGENT=""

COLOR_RESET=$'\033[0m'

color_for_level() {
  case "$1" in
    info)   printf '\033[1;36m' ;;
    warn)   printf '\033[1;33m' ;;
    error)  printf '\033[1;31m' ;;
    agent)  printf '\033[1;35m' ;;
    debug)  printf '\033[0;37m' ;;
    *)      printf '\033[0m' ;;
  esac
}

print_debug() {
  local level="$1"
  shift
  local message="$*"
  local color
  color=$(color_for_level "$level")
  printf '%b[%s] %-6s%b %s\n' "$color" "$(date '+%H:%M:%S')" "$level" "$COLOR_RESET" "$message"
}

log_event() {
  local message="$1"
  printf '%s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$message" >> "$ACTIVITY_LOG"
}

log_status() {
  local level="$1"
  shift
  local message="$*"
  log_event "[$level] $message"
  print_debug "$level" "$message"
}

agent_pane_exists() {
  tmux list-panes -t "$AGENT_PANE" >/dev/null 2>&1
}

send_to_agent() {
  local text="${1//$'\n'/ }"
  if tmux has-session -t "$SESSION" 2>/dev/null && agent_pane_exists; then
    if [[ "$(tmux display-message -p -t "$AGENT_PANE" '#{pane_in_mode}')" == "1" ]]; then
      tmux send-keys -t "$AGENT_PANE" q
      sleep 0.02
    fi

    tmux send-keys -t "$AGENT_PANE" -l -- "$text"
    sleep 0.05

    tmux send-keys -t "$AGENT_PANE" C-j
    sleep 0.03
    tmux send-keys -t "$AGENT_PANE" -l -- $'\r\n'
    sleep 0.03
    tmux send-keys -t "$AGENT_PANE" KPEnter
  else
    log_status error "Cannot reach agent pane ($AGENT_PANE). Message skipped: $text"
  fi
}

load_last_line() {
  if [[ -f "$LAST_LINE_FILE" ]]; then
    read -r LAST_LINE < "$LAST_LINE_FILE" || LAST_LINE=0
  else
    LAST_LINE=0
  fi
}

save_last_line() {
  printf '%s\n' "$1" > "$LAST_LINE_FILE"
}

setup_workspace() {
  cat > "$WORKSPACE/SPEC.md" <<'EOF'
# Workspace Specification

This workspace contains:
- `cli.log`   — All CLI commands and output
- `capcom.log` — Capcom monitor and debug log
- `SPEC.md`   — This specification file

Hashtag triggers in `cli.log`:
- `#q <message>` — forward to active assistant
- `#askagent <message>` / `#askhelp <message>` — request detailed support
- `#changeagent <name>` — switch assistant (`codex`, `q`, `gemini`, `droid`)

Capcom forwards context to the active agent and records activity here.
EOF
  log_status info "Workspace SPEC refreshed"
}

detect_agents() {
  AVAILABLE_AGENTS=()
  for agent in "${PRIORITY_AGENTS[@]}"; do
    if command -v "$agent" >/dev/null 2>&1; then
      AVAILABLE_AGENTS+=("$agent")
    fi
  done

  if [[ ${#AVAILABLE_AGENTS[@]} -gt 0 ]]; then
    log_status info "Detected agents: ${AVAILABLE_AGENTS[*]}"
  else
    log_status warn "No preferred agent CLIs detected (codex/q/gemini/droid)."
  fi
}

agent_is_available() {
  local target="$1"
  for agent in "${AVAILABLE_AGENTS[@]}"; do
    [[ "$agent" == "$target" ]] && return 0
  done
  return 1
}

select_default_agent() {
  DEFAULT_AGENT=""
  for candidate in "${PRIORITY_AGENTS[@]}"; do
    if agent_is_available "$candidate"; then
      DEFAULT_AGENT="$candidate"
      break
    fi
  done
  if [[ -n "$DEFAULT_AGENT" ]]; then
    log_status agent "Default agent: $DEFAULT_AGENT"
  fi
}

activate_agent() {
  local agent="$1"

  if [[ -z "$agent" ]]; then
    log_status warn "No agent specified for activation"
    return 1
  fi

  if ! command -v "$agent" >/dev/null 2>&1; then
    log_status warn "Agent '$agent' is not installed"
    return 1
  fi

  if ! agent_pane_exists; then
    log_status error "Agent pane $AGENT_PANE not found"
    return 1
  fi

  local command="${AGENT_COMMANDS[$agent]:-$agent}"
  if [[ "$agent" == "codex" ]]; then
    command+=" --sandbox $CODEX_SANDBOX_MODE"
  fi

  tmux send-keys -t "$AGENT_PANE" C-c
  tmux send-keys -t "$AGENT_PANE" "cd '$WORKSPACE'" C-m
  tmux send-keys -t "$AGENT_PANE" "$command" C-m

  CURRENT_AGENT="$agent"
  log_status agent "Switched to agent '$agent' using command: $command"
  return 0
}

wait_for_log() {
  log_status info "Waiting for CLI log at $LOG_FILE"
  until [[ -f "$LOG_FILE" ]]; do
    sleep 1
  done
}

handle_change_agent() {
  local requested="${1,,}"
  requested="${requested%%[[:space:]]*}"

  if [[ -z "$requested" ]]; then
    log_status warn "#changeagent invoked without specifying a target"
    return
  fi

  if ! agent_is_available "$requested"; then
    if command -v "$requested" >/dev/null 2>&1; then
      AVAILABLE_AGENTS+=("$requested")
      log_status info "Discovered additional agent '$requested'"
    else
      log_status warn "Requested agent '$requested' is not available"
      return
    fi
  fi

  if [[ "$requested" == "$CURRENT_AGENT" ]]; then
    log_status info "Agent '$requested' is already active"
    return
  fi

  if activate_agent "$requested"; then
    sleep 1
    send_to_agent "read spec"
    sleep 1
    send_to_agent "Team leader needs your help. Review cli.log for latest requests."
  fi
}

initialize_capcom() {
  print_debug info "Capcom console ready"
  setup_workspace
  wait_for_log
  detect_agents
  select_default_agent

  if [[ -n "$DEFAULT_AGENT" ]]; then
    if activate_agent "$DEFAULT_AGENT"; then
      sleep 1
      send_to_agent "read spec"
      sleep 1
      send_to_agent "Team leader needs your help. Monitor cli.log for #askagent or #askhelp."
    fi
  else
    log_status warn "No agent started automatically — attach to pane and launch manually."
  fi
}

monitor_and_poke() {
  initialize_capcom

  load_last_line
  tail -n "+$((LAST_LINE + 1))" -F "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
    LAST_LINE=$((LAST_LINE + 1))
    save_last_line "$LAST_LINE"
    log_event "CLI[$LAST_LINE]: $line"

    if [[ "$line" == "[MENU]"* ]]; then
      continue
    fi

    if [[ "$line" =~ \#changeagent[[:space:]]+([A-Za-z0-9_-]+) ]]; then
      log_status info "Detected #changeagent request for '${BASH_REMATCH[1]}'"
      handle_change_agent "${BASH_REMATCH[1]}"
      continue
    fi

    if [[ "$line" =~ \#(q|askagent|askhelp)[[:space:]]*(.*) ]]; then
      local trigger="${BASH_REMATCH[1]}"
      local request="${BASH_REMATCH[2]}"
      request="${request#"${request%%[![:space:]]*}"}"
      request="${request%"${request##*[![:space:]]}"}"
      if [[ -z "$request" ]]; then
        request="No additional details supplied."
      fi

      local context_start=$(( LAST_LINE > 200 ? LAST_LINE - 200 : 1 ))
      log_status info "Forwarding #$trigger request from line $LAST_LINE"

      send_to_agent "Team leader needs your help (agent: ${CURRENT_AGENT:-unknown}). Trigger: #$trigger at cli.log line $LAST_LINE. Review $LOG_FILE from line $context_start for context. Request: $request"
      log_event "Poked agent '$CURRENT_AGENT' for #$trigger (line $LAST_LINE)"
    fi
  done
}

monitor_and_poke
