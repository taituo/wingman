#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINGMAN_SCRIPT="$PROJECT_ROOT/wingman.sh"
WORKSPACES_DIR="$PROJECT_ROOT/workspaces"
mkdir -p "$WORKSPACES_DIR"

prompt() {
  local prompt_text="$1"
  read -rp "$prompt_text" REPLY
  echo "$REPLY"
}

next_workspace_name() {
  local idx=1
  while :; do
    local candidate
    candidate=$(printf "workspace_%03d" "$idx")
    if [[ ! -e "$WORKSPACES_DIR/$candidate" ]]; then
      echo "$candidate"
      return
    fi
    idx=$((idx+1))
  done
}

workspace_path() {
  local name="$1"
  echo "$WORKSPACES_DIR/$name"
}

workspace_session() {
  local name="$1"
  echo "ws_${name}"
}

ensure_workspace_structure() {
  local ws_path="$1"
  mkdir -p "$ws_path/logs"
}

record_workspace_meta() {
  local ws_name="$1" key="$2" value="$3"
  local meta_file="$WORKSPACES_DIR/$ws_name/.workspace"
  mkdir -p "$(dirname "$meta_file")"
  if [[ -f "$meta_file" ]]; then
    grep -v "^$key=" "$meta_file" >"$meta_file.tmp" && mv "$meta_file.tmp" "$meta_file"
  fi
  printf '%s=%s\n' "$key" "$value" >>"$meta_file"
}

list_workspaces() {
  local ws
  printf '%-15s %-10s %-20s\n' "Workspace" "State" "Session"
  for ws in $(ls "$WORKSPACES_DIR" 2>/dev/null | sort); do
    [[ -d "$WORKSPACES_DIR/$ws" ]] || continue
    local meta="$WORKSPACES_DIR/$ws/.workspace"
    local session=""
    local state="idle"
    if [[ -f "$meta" ]]; then
      session=$(grep '^session=' "$meta" | head -n1 | cut -d= -f2- || true)
    fi
    if [[ -n "$session" && $(tmux has-session -t "$session" 2>/dev/null && echo running) ]]; then
      state="running"
    fi
    printf '%-15s %-10s %-20s\n' "$ws" "$state" "${session:-}"
  done
}

start_wingman_workspace() {
  local ws_name="$1"
  local ws_path
  ws_path=$(workspace_path "$ws_name")
  ensure_workspace_structure "$ws_path"
  local session
  session=$(workspace_session "$ws_name")
  record_workspace_meta "$ws_name" session "$session"
  record_workspace_meta "$ws_name" mode "wingman"

  echo "Launching wingman workspace '$ws_name' (session: $session)"

  # Set environment for wingman
  env \
    SESSION="$session" \
    WORKSPACE="$ws_path" \
    "$WINGMAN_SCRIPT"
}

attach_workspace() {
  list_workspaces
  local choice
  choice=$(prompt 'Workspace to attach (name): ')
  [[ -n "$choice" ]] || return
  local meta="$WORKSPACES_DIR/$choice/.workspace"
  if [[ ! -f "$meta" ]]; then
    echo "Unknown workspace." >&2
    return
  fi
  local session
  session=$(grep '^session=' "$meta" | head -n1 | cut -d= -f2- || true)
  if [[ -z "$session" ]]; then
    echo "Workspace has no recorded session." >&2
    return
  fi
  if tmux has-session -t "$session" 2>/dev/null; then
    tmux attach -t "$session"
  else
    echo "Session $session not running." >&2
  fi
}

stop_workspace() {
  list_workspaces
  local choice
  choice=$(prompt 'Workspace to stop (name): ')
  choice="${choice#"${choice%%[![:space:]]*}"}"
  choice="${choice%"${choice##*[![:space:]]}"}"
  [[ -n "$choice" ]] || return
  local ws_path
  ws_path=$(workspace_path "$choice")
  if [[ ! -d "$ws_path" ]]; then
    echo "Workspace $choice not found." >&2
    return
  fi

  local meta="$ws_path/.workspace"
  local session=""
  if [[ -f "$meta" ]]; then
    session=$(grep '^session=' "$meta" | head -n1 | cut -d= -f2- || true)
  fi
  if [[ -n "$session" ]]; then
    if ! SESSION="$session" "$WINGMAN_SCRIPT" stop >/dev/null 2>&1; then
      tmux kill-session -t "$session" 2>/dev/null || true
    fi
  fi
  rm -rf -- "$ws_path"
  if [[ -d "$ws_path" ]]; then
    echo "Failed to remove workspace directory $ws_path" >&2
  else
    echo "Workspace $choice removed."
  fi
}

start_interactive_menu() {
  while true; do
    cat <<'MENU'

🎯 WINGMAN — Command Center
1) Start wingman workspace (CLI | Amazon Q)
2) Attach to existing workspace
3) Stop & remove workspace
4) List workspaces
5) Exit
MENU
    local choice
    choice=$(prompt 'Select option: ')
    case "$choice" in
      1)
        local ws_name=$(next_workspace_name)
        start_wingman_workspace "$ws_name" ;;
      2)
        attach_workspace ;;
      3)
        stop_workspace ;;
      4)
        list_workspaces ;;
      5)
        echo "Bye."; break ;;
      *)
        echo "Unknown selection." ;;
    esac
  done
}

start_interactive_menu
