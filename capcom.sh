#!/usr/bin/env bash
set -euo pipefail

# capcom: monitors CLI logs and orchestrates assistant agents
HOME_DIR="${HOME:-/root}"
WORKSPACE="${WORKSPACE:-}"
LOG_FILE="${LOG_FILE:-}"
SESSION="${SESSION:-}"
AGENT_PANE="${AGENT_PANE:-${SESSION}:0.1}"
NOTIFICATION_LOG="${NOTIFICATION_LOG:-}"
TMUX_ARCHIVE_ROOT="${TMUX_ARCHIVE_ROOT:-$HOME_DIR/tmux}"
PANE_LOGGER="${PANE_LOGGER:-}"
ACTIVITY_LOG="$WORKSPACE/capcom.log"
LAST_LINE_FILE="$WORKSPACE/.capcom_last_line"
SESSION_ARCHIVE="$TMUX_ARCHIVE_ROOT/$SESSION"
ERROR_POKE_INTERVAL=${ERROR_POKE_INTERVAL:-120}
LAST_ERROR_POKE=0
LAST_ERROR_LINE=""

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

notification_color() {
  case "$1" in
    info)  printf '\033[38;5;33m' ;;
    warn)  printf '\033[38;5;214m' ;;
    error) printf '\033[38;5;196m' ;;
    agent) printf '\033[38;5;207m' ;;
    *)     printf '\033[38;5;250m' ;;
  esac
}

append_notification() {
  local level="$1"
  shift
  local message="$*"
  [[ -z "$NOTIFICATION_LOG" ]] && return
  mkdir -p "$(dirname "$NOTIFICATION_LOG")"
  local color
  color=$(notification_color "$level")

  printf '%b[%s] %-5s%b %s\n' "$color" "$(date '+%H:%M:%S')" "$level" "$COLOR_RESET" "$message" >>"$NOTIFICATION_LOG"
}

sanitize_name() {
  local raw="$1"
  raw="${raw,,}"
  raw="${raw//[^a-z0-9_]/_}"
  raw="${raw##_}"
  raw="${raw%%_}"
  printf '%s' "${raw:-pane}"
}

configure_pane_logging() {
  [[ -z "$PANE_LOGGER" || ! -x "$PANE_LOGGER" ]] && return
  mkdir -p "$SESSION_ARCHIVE/panes"
  while IFS=$'\t' read -r target pane_id pane_title; do
    local session_name=${target%%:*}
    [[ "$session_name" != "$SESSION" ]] && continue
    [[ -z "$pane_id" ]] && continue
    [[ -z "$pane_id" ]] && continue
    local name
    if [[ -n "$pane_title" ]]; then
      name=$(sanitize_name "$pane_title")
    else
      name=$(sanitize_name "${pane_id#%}")
    fi
    local pane_dir="$SESSION_ARCHIVE/panes/${name}_${pane_id#%}"
    tmux pipe-pane -t "$target" "LOG_DIR=$pane_dir $PANE_LOGGER"
  done < <(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}	#{pane_id}	#{pane_title}' 2>/dev/null || true)
  log_status info "Pane logging configured under $SESSION_ARCHIVE/panes"
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
    append_notification error "Agent pane unreachable. Message skipped."
  fi
}

compose_agent_prompt() {
  local trigger="$1"
  local request="$2"
  local context_start="$3"
  local current_line="$4"
  local friendly_prefix

  case "$trigger" in
    askhelp|test1|test2)
      friendly_prefix="Friendly Wingman here—offer supportive guidance and encouragement."
      ;;
    askagent)
      friendly_prefix="Wingman analysis mode: highlight potential pitfalls and next steps clearly."
      ;;
    q)
      friendly_prefix="Wingman quick assist: deliver concise, actionable insight promptly."
      ;;
    *)
      friendly_prefix="Wingman notice: respond helpfully."
      ;;
  esac

  printf '%s Trigger #%s spotted in cli.log at line %s. Review %s starting from line %s and respond to the teammate message: %s' \
    "$friendly_prefix" "$trigger" "$current_line" "$LOG_FILE" "$context_start" "$request"
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
  mkdir -p "$SESSION_ARCHIVE"
  cat > "$WORKSPACE/SPEC.md" <<'EOF'
# Workspace Specification

This workspace contains:
- `cli.log`   — All CLI commands and output
- `capcom.log` — Capcom monitor and debug log
- `SPEC.md`   — This specification file

Tmux layout:
- Window 0 pane 0 (`CLI`): primary shell (mirrored into cli.log and pane archives)
- Window 0 pane 1 (`Notifications`): tails notifications log
- Window 1 pane 0 (`Eye`): launch Codex/Q/Droid when needed
- Window 1 pane 1 (`Capcom`): this monitor console

Hashtag triggers in `cli.log`:
- `#q <message>` — forward to active assistant
- `#askagent <message>` / `#askhelp <message>` — request detailed support
- `#test1 <message>` / `#test2 <message>` — diagnostics for friendly feedback loops
- `#changeagent <name>` — switch assistant (`codex`, `q`, `gemini`, `droid`)

Capcom forwards context to the active agent and records activity here.
EOF
  log_status info "Workspace SPEC refreshed"
  append_notification info "Capcom online. Monitoring session '$SESSION'."
}


should_flag_error_line() {
  local line="${1,,}"
  [[ -z "$line" ]] && return 1
  [[ "${line:0:1}" == "#" ]] && return 1
  if [[ "$line" == traceback* ]]; then
    return 0
  fi
  if [[ "$line" == *error* || "$line" == *exception* || "$line" == *failed* ]]; then
    return 0
  fi
  return 1
}

handle_cli_error_line() {
  local original="$1"
  local now
  now=$(date +%s)
  if (( now - LAST_ERROR_POKE < ERROR_POKE_INTERVAL )); then
    LAST_ERROR_LINE="$original"
    return
  fi
  LAST_ERROR_POKE=$now
  LAST_ERROR_LINE="$original"
  append_notification warn "Detected possible issue in CLI: $original"
  log_status warn "Detected possible CLI failure: $original"
  if [[ -n "$CURRENT_AGENT" ]]; then
    send_to_agent "Wingman spotted a possible failure around cli.log line $LAST_LINE. Review recent output and help the teammate recover."
    append_notification agent "Requested $CURRENT_AGENT to assist with recent CLI issue."
  else
    append_notification info "No agent active to assist with the detected issue."
  fi
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
    append_notification agent "Agents ready: ${AVAILABLE_AGENTS[*]}"
  else
    log_status warn "No preferred agent CLIs detected (codex/q/gemini/droid)."
    append_notification warn "No agent CLI detected. Launch manually if available."
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
  append_notification agent "Agent '$agent' now active."
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
  configure_pane_logging
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
    append_notification warn "No agent auto-started. Use tmux keybinds or #changeagent to begin."
  fi
}

monitor_and_poke() {
  initialize_capcom

  load_last_line
  tail -n "+$((LAST_LINE + 1))" -F "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
    LAST_LINE=$((LAST_LINE + 1))
    save_last_line "$LAST_LINE"

    local clean_line="${line//$'\r'/}"
    clean_line="${clean_line%$'\n'}"
    local trimmed="${clean_line#"${clean_line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    log_event "CLI[$LAST_LINE]: $trimmed"

    if [[ "$trimmed" == "[MENU]"* ]]; then
      continue
    fi

    if [[ "$trimmed" =~ ^#changeagent[[:space:]]+([A-Za-z0-9_-]+) ]]; then
      log_status info "Detected #changeagent request for '${BASH_REMATCH[1]}'"
      handle_change_agent "${BASH_REMATCH[1]}"
      continue
    fi

    if should_flag_error_line "$trimmed"; then
      handle_cli_error_line "$trimmed"
    fi

    if [[ "$trimmed" =~ ^#(q|askagent|askhelp|test1|test2)[[:space:]]*(.*)$ ]]; then
      local trigger="${BASH_REMATCH[1]}"
      local request="${BASH_REMATCH[2]}"
      request="${request#"${request%%[![:space:]]*}"}"
      request="${request%"${request##*[![:space:]]}"}"
      if [[ -z "$request" ]]; then
        request="No additional details supplied."
      fi

      local context_start=$(( LAST_LINE > 200 ? LAST_LINE - 200 : 1 ))
      log_status info "Forwarding #$trigger request from line $LAST_LINE"
      local prompt
      prompt=$(compose_agent_prompt "$trigger" "$request" "$context_start" "$LAST_LINE")
      send_to_agent "$prompt"
      append_notification agent "Forwarded #$trigger request to agent."
      log_event "Poked agent '$CURRENT_AGENT' for #$trigger (line $LAST_LINE)"
    fi
  done
}

monitor_and_poke
