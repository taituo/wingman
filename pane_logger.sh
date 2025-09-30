 #!/usr/bin/env bash
 set -euo pipefail

 LOG_DIR="${LOG_DIR:-}"

 if [[ -z "$LOG_DIR" ]]; then
   echo "LOG_DIR not set" >&2
   exit 1
 fi

 mkdir -p "$LOG_DIR"

 while IFS= read -r line; do
   [[ -z "$line" ]] && continue
   minute_stamp="$(date '+%Y%m%d_%H%M')"
   log_file="$LOG_DIR/$minute_stamp.log"
   printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line" >>"$log_file"
 done
