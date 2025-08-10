#!/usr/bin/env bash
# Terraform presence/version check + optional install with robust logging.
# Works on macOS/Linux for x86_64 and arm64/aarch64.

set -u

# -------- CONFIG --------
LOG_FILE="${HOME}/terraform_install.log"      # Single log file for warnings/errors
MAX_LOG_LINES=100                             # Keep last 100 log entries
CHECKPOINT_URL="https://checkpoint-api.hashicorp.com/v1/check/terraform"
RELEASES_BASE="https://releases.hashicorp.com/terraform"
# ------------------------

# Minimal dependencies checkers (avoid jq dependency)
have_cmd() { command -v "$1" >/dev/null 2>&1; }

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }

# Thread-safe-ish append: one line per call to avoid interleaving
log_line() {
  # $1 = "ERROR" or "WARNING"; $2... = message
  local level="$1"; shift
  local msg="$*"
  printf "%s  %s: %s\n" "$(timestamp)" "${level}" "${msg}" >> "$LOG_FILE"
  trim_log
}

trim_log() {
  # Keep only the last MAX_LOG_LINES lines
  if [ -f "$LOG_FILE" ]; then
    local lines
    lines=$(wc -l < "$LOG_FILE" | tr -d ' ')
    if [ "$lines" -gt "$MAX_LOG_LINES" ]; then
      tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
  fi
}

# Parse JSON "current_version" from checkpoint API without jq
parse_current_version() {
  # Read JSON from stdin; output version string
  # Works with sed/awk; tolerant to whitespace
  awk '
    match($0, /"current_version"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"/) {
      s=substr($0, RSTART, RLENGTH);
      sub(/.*"[[:space:]]*:[[:space:]]*"/, "", s);
      sub(/"$/, "", s);
      print s; exit 0
    }
  '
}

get_latest_version() {
  # Echo latest version or empty on failure
  local json ver
  json=$(curl -fsSL "$CHECKPOINT_URL" 2> >(while read -r line; do
    # classify stderr lines
    if echo "$line" | grep -qi "warning"; then
      log_line "WARNING" "curl checkpoint: $line"
    else
      log_line "ERROR" "curl checkpoint: $line"
    fi
  done))
  if [ $? -ne 0 ] || [ -z "${json:-}" ]; then
    return 1
  fi
  ver=$(printf "%s\n" "$json" | parse_current_version)
  [ -n "$ver" ] && printf "%s" "$ver" || return 1
}

get_os_arch() {
  # Echo "<os> <arch>" mapped to HashiCorp naming
  local os arch
  case "$(uname -s)" in
    Linux)   os="linux" ;;
    Darwin)  os="darwin" ;;
    *) echo "Unsupported OS: $(uname -s)"; return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) echo "Unsupported architecture: $(uname -m)"; return 1 ;;
  esac
  echo "$os $arch"
}

# Extract terraform version from installed binary
installed_tf_version() {
  local out ver
  if have_cmd terraform; then
    # Try JSON flag first (Terraform >= 0.15)
    out=$(terraform version -json 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "${out}" ]; then
      ver=$(printf "%s\n" "$out" | awk '
        match($0, /"terraform_version"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"/) {
          s=substr($0, RSTART, RLENGTH);
          sub(/.*"[[:space:]]*:[[:space:]]*"/, "", s);
          sub(/"$/, "", s);
          print s; exit 0
        }
      ')
      if [ -n "$ver" ]; then
        printf "%s" "$ver"
        return 0
      fi
    fi
    # Fallback: parse human output "Terraform v1.8.5"
    ver=$(terraform version 2>/dev/null | head -n1 | sed -n 's/.* v\([0-9]\+\.[0-9]\+\.[0-9]\+\).*/\1/p')
    [ -n "$ver" ] && printf "%s" "$ver" && return 0
  fi
  return 1
}

version_lt() {
  # Return 0 if $1 < $2 (semver-ish)
  # Strip leading "v" if present
  local a="${1#v}" b="${2#v}"
  # Normalize to X.Y.Z
  IFS=. read -r a1 a2 a3 <<<"${a}"
  IFS=. read -r b1 b2 b3 <<<"${b}"
  a1=${a1:-0}; a2=${a2:-0}; a3=${a3:-0}
  b1=${b1:-0}; b2=${b2:-0}; b3=${b3:-0}
  if [ "$a1" -lt "$b1" ]; then return 0; fi
  if [ "$a1" -gt "$b1" ]; then return 1; fi
  if [ "$a2" -lt "$b2" ]; then return 0; fi
  if [ "$a2" -gt "$b2" ]; then return 1; fi
  if [ "$a3" -lt "$b3" ]; then return 0; fi
  return 1
}

choose_install_dir() {
  # Prefer /usr/local/bin if writable; else ~/.local/bin
  local target
  if [ -w "/usr/local/bin" ]; then
    target="/usr/local/bin"
  else
    target="${HOME}/.local/bin"
    mkdir -p "$target" 2>/dev/null || true
  fi
  printf "%s" "$target"
}

# -------- unzip prerequisite (APT-based) --------

installed_unzip_version() {
  if have_cmd unzip; then
    # Example first line: "UnZip 6.00 of 20 April 2009, by Debian..."
    unzip -v 2>/dev/null | head -n1 | sed -n 's/^UnZip \([0-9][0-9.]*\).*/\1/p'
    return 0
  fi
  return 1
}

install_unzip_if_needed() {
  if have_cmd unzip; then
    local uv
    uv="$(installed_unzip_version || true)"
    if [ -n "$uv" ]; then
      echo "unzip is already present. Installed version: ${uv}"
    else
      echo "unzip is already present."
    fi
    return 0
  fi

  echo "unzip not found. Installing via apt-get…"
  # Try apt-get install -y unzip with sudo if needed; log stderr like other steps
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    apt-get install -y unzip 1>/dev/null 2> >(while read -r line; do
      if echo "$line" | grep -qi "warning"; then
        log_line "WARNING" "apt-get install unzip: $line"
      else
        log_line "ERROR"   "apt-get install unzip: $line"
      fi
    done)
  elif have_cmd sudo; then
    sudo apt-get install -y unzip 1>/dev/null 2> >(while read -r line; do
      if echo "$line" | grep -qi "warning"; then
        log_line "WARNING" "sudo apt-get install unzip: $line"
      else
        log_line "ERROR"   "sudo apt-get install unzip: $line"
      fi
    done)
  else
    log_line "ERROR" "Cannot install unzip: not root and sudo not available"
    echo "Need root privileges to install 'unzip' (apt-get). See log: $LOG_FILE"
    return 1
  fi

  if ! have_cmd unzip; then
    log_line "ERROR" "unzip not found after apt-get install"
    echo "'unzip' not found after installation. See log: $LOG_FILE"
    return 1
  fi

  local uv
  uv="$(installed_unzip_version || true)"
  if [ -n "$uv" ]; then
    echo "'unzip' installed successfully. Version: ${uv}"
  else
    echo "'unzip' installed successfully."
  fi
  return 0
}

# -------- Terraform install --------

download_and_install_tf() {
  local latest os arch url tmpdir zipfile instdir
  latest="$1"
  read -r os arch < <(get_os_arch) || {
    log_line "ERROR" "OS/Arch detection failed"
    echo "Failed to detect OS/Arch. See log: $LOG_FILE"
    return 1
  }
  url="${RELEASES_BASE}/${latest}/terraform_${latest}_${os}_${arch}.zip"
  tmpdir="$(mktemp -d)"
  zipfile="${tmpdir}/terraform.zip"

  # Download
  curl -fSL "$url" -o "$zipfile" 2> >(while read -r line; do
    if echo "$line" | grep -qi "warning"; then
      log_line "WARNING" "curl download: $line"
    else
      log_line "ERROR" "curl download: $line"
    fi
  done)
  if [ $? -ne 0 ]; then
    log_line "ERROR" "Failed to download ${url}"
    echo "Download failed. See log: $LOG_FILE"
    rm -rf "$tmpdir"
    return 1
  fi

  # Ensure unzip present (guard, though we already installed if needed)
  if ! have_cmd unzip; then
    log_line "ERROR" "unzip not found; cannot extract Terraform archive"
    echo "'unzip' not found. Install it (e.g., 'apt-get install unzip') and retry. See log: $LOG_FILE"
    rm -rf "$tmpdir"
    return 1
  fi

  (cd "$tmpdir" && unzip -o "$zipfile") 2> >(while read -r line; do
    if echo "$line" | grep -qi "warning"; then
      log_line "WARNING" "unzip: $line"
    else
      log_line "ERROR" "unzip: $line"
    fi
  done)
  if [ $? -ne 0 ] || [ ! -f "${tmpdir}/terraform" ]; then
    log_line "ERROR" "Failed to unzip Terraform archive"
    echo "Extraction failed. See log: $LOG_FILE"
    rm -rf "$tmpdir"
    return 1
  fi

  instdir=$(choose_install_dir)
  # Move into place
  mv "${tmpdir}/terraform" "${instdir}/terraform" 2> >(while read -r line; do
    if echo "$line" | grep -qi "warning"; then
      log_line "WARNING" "move: $line"
    else
      log_line "ERROR" "move: $line"
    fi
  done)
  if [ $? -ne 0 ]; then
    # Try with sudo if available and /usr/local/bin is target
    if [ "$instdir" = "/usr/local/bin" ] && have_cmd sudo; then
      sudo mv "${tmpdir}/terraform" "${instdir}/terraform" 2> >(while read -r line; do
        if echo "$line" | grep -qi "warning"; then
          log_line "WARNING" "sudo move: $line"
        else
          log_line "ERROR" "sudo move: $line"
        fi
      done) || {
        log_line "ERROR" "Failed to install Terraform into ${instdir}"
        echo "Install failed. See log: $LOG_FILE"
        rm -rf "$tmpdir"
        return 1
      }
    else
      log_line "ERROR" "Failed to install Terraform into ${instdir}"
      echo "Install failed. See log: $LOG_FILE"
      rm -rf "$tmpdir"
      return 1
    fi
  fi

  chmod +x "${instdir}/terraform" 2>/dev/null || true
  rm -rf "$tmpdir"

  # PATH hint
  if ! printf "%s" "$PATH" | tr ':' '\n' | grep -qx "$instdir"; then
    echo "Note: ${instdir} is not in your PATH. Add this to your shell profile:"
    echo "  export PATH=\"${instdir}:\$PATH\""
  fi

  echo "Terraform ${latest} installed to ${instdir}/terraform"
}

main() {
  # 1) Check if Terraform is present
  if have_cmd terraform; then
    # Present: print version and compare to latest
    local installed latest
    installed=$(installed_tf_version || true)
    if [ -n "$installed" ]; then
      echo "Terraform is already present. Installed version: ${installed}"
    else
      echo "Terraform is present but version parsing failed (suspicious)."
    fi

    latest=$(get_latest_version || true)
    if [ -z "$latest" ]; then
      echo "Could not determine latest Terraform version (network or parse issue). See log: $LOG_FILE"
      exit 0
    fi

    if [ -n "$installed" ] && version_lt "$installed" "$latest"; then
      echo "A newer version is available: ${latest}. You can download the latest version."
    else
      echo "You have the latest version (${latest}) or a newer build."
    fi
  else
    # Not present: fetch latest and install
    echo "Terraform not found. Fetching latest version metadata…"
    local latest
    latest=$(get_latest_version)
    if [ $? -ne 0 ] || [ -z "$latest" ]; then
      echo "Failed to get latest version. See log: $LOG_FILE"
      exit 1
    fi

    # NEW: ensure unzip prerequisite using apt-get (same logging style)
    if ! install_unzip_if_needed; then
      exit 1
    fi

    echo "Latest Terraform version is ${latest}. Downloading and installing…"
    download_and_install_tf "$latest" || exit 1
  fi
}

main "$@"