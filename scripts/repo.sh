#!/usr/bin/env bash
# Clone a repository into $HOME if not present, with capped logging of repo-related issues.

set -u

# ========= Config =========
LOG_FILE="${LOG_FILE:-$HOME/repo_clone.log}"   # single shared log file
MAX_LOGS=100                                   # keep last 100 log entries
# ==========================

have_cmd() { command -v "$1" >/dev/null 2>&1; }
timestamp() { date "+%Y-%m-%d %H:%M:%S"; }

log_line() {
  # $1 = LEVEL (ERROR|WARNING), $2... = message
  local level="$1"; shift
  printf "%s  %s: %s\n" "$(timestamp)" "$level" "$*" >> "$LOG_FILE"
  trim_log
}

trim_log() {
  # Cap the log to last MAX_LOGS lines
  if [ -f "$LOG_FILE" ]; then
    local lines
    lines=$(wc -l < "$LOG_FILE" | tr -d ' ')
    if [ "$lines" -gt "$MAX_LOGS" ]; then
      tail -n "$MAX_LOGS" "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
  fi
}

# Classify and log only repo-related warnings/errors from a combined output file
log_repo_issues_from_file() {
  # $1 = path to temp output file
  local f="$1" line
  [ -s "$f" ] || return 0

  # Patterns considered repo-related; keep it general per your request
  local err_pat warn_pat
  err_pat='(fatal:|error:|denied|not found|could not|refused|timed out|remote hung up|host key|permission denied|authentication failed|repository .* does not exist|SSL|unable|proxy|HTTP[^0-9]*[45][0-9]{2})'
  warn_pat='(warning:|deprecated|advice:)'

  # Read line by line to preserve exact messages
  while IFS= read -r line; do
    if echo "$line" | grep -Eiq "$err_pat"; then
      log_line "ERROR" "$line"
    elif echo "$line" | grep -Eiq "$warn_pat"; then
      log_line "WARNING" "$line"
    fi
  done < "$f"
}

# -------- Main flow --------
main() {
  # 0) Require REPO_URL
  if [ -z "${REPO_URL:-}" ]; then
    echo "REPO_URL is not set. Example: export REPO_URL=\"https://github.com/org/project.git\""
    exit 1
  fi

  # 1) Derive destination as $HOME/<repo-basename>
  #    (strip trailing .git and everything before the last slash)
  local repo_name dest_dir
  repo_name="$(basename "${REPO_URL%/}")"
  repo_name="${repo_name%.git}"
  if [ -z "$repo_name" ] || [ "$repo_name" = "/" ] || [ "$repo_name" = "." ]; then
    echo "Could not resolve repository name from REPO_URL: $REPO_URL"
    exit 1
  fi
  dest_dir="$HOME/$repo_name"

  # 2) General presence check (no deep git inspection)
  if [ -d "$dest_dir" ]; then
    echo "Repository is present in the machine."
    exit 0
  fi

  # 3) Clone if missing
  echo "Cloning repository into your machine..."
  local tmp_out rc=0
  tmp_out="$(mktemp)"
  if ! have_cmd git; then
    log_line "ERROR" "git command not found on PATH"
    echo "git is not installed or not on PATH. See log: $LOG_FILE"
    rm -f "$tmp_out"
    exit 2
  fi

  git clone "$REPO_URL" "$dest_dir" >"$tmp_out" 2>&1 || rc=$?
  # Log only repo-related warnings/errors
  log_repo_issues_from_file "$tmp_out"
  rm -f "$tmp_out"

  if [ $rc -ne 0 ]; then
    echo "Clone failed. See log: $LOG_FILE"
    exit 2
  fi

  echo "Repository cloned to $dest_dir"
  exit 0
}

main "$@"
