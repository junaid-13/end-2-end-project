#!/usr/bin/env bash
# Terraform presence/version check + optional install with robust logging.
# Ensures 'unzip' via apt-get before installing Terraform.
# Prefers /usr/local/bin (with sudo if needed); falls back to ~/.local/bin.
# If we fall back, add install dir to PATH for current session.

set -u

# -------- CONFIG --------
LOG_FILE="${HOME}/terraform_install.log"      # Single log file for warnings/errors
MAX_LOG_LINES=100                             # Keep last 100 log entries
CHECKPOINT_URL="https://checkpoint-api.hashicorp.com/v1/check/terraform"
RELEASES_BASE="https://releases.hashicorp.com/terraform"
# ------------------------

have_cmd() { command -v "$1" >/dev/null 2>&1; }
timestamp() { date "+%Y-%m-%d %H:%M:%S"; }

log_line() {
  local level="$1"; shift
  local msg="$*"
  printf "%s  %s: %s\n" "$(timestamp)" "${level}" "${msg}" >> "$LOG_FILE"
  trim_log
}

trim_log() {
  if [ -f "$LOG_FILE" ]; then
    local lines
    lines=$(wc -l < "$LOG_FILE" | tr -d ' ')
    if [ "$lines" -gt "$MAX_LOG_LINES" ]; then
      tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
  fi
}

capture_and_log_stderr() {
  local tag="$1" tmp="$2"
  if [ -s "$tmp" ]; then
    while IFS= read -r line; do
      if echo "$line" | grep -qi "warning"; then
        log_line "WARNING" "${tag}: $line"
      else
        log_line "ERROR"   "${tag}: $line"
      fi
    done < "$tmp"
  fi
  rm -f "$tmp"
}

parse_current_version() {
  awk '
    match($0, /"current_version"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"/) {
      s=substr($0, RSTART, RLENGTH)
      sub(/.*:[[:space:]]*"/, "", s)
      sub(/"$/, "", s)
      print s; exit 0
    }
  '
}

get_latest_version() {
  local tmp_err json ver
  tmp_err="$(mktemp)"
  json="$(curl -fsSL "$CHECKPOINT_URL" 2>"$tmp_err")" || true
  capture_and_log_stderr "curl checkpoint" "$tmp_err"
  [ -n "${json:-}" ] || return 1
  ver=$(printf "%s\n" "$json" | parse_current_version)
  [ -n "$ver" ] && printf "%s" "$ver" || return 1
}

get_os_arch() {
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

# -------- unzip prerequisite --------
installed_unzip_version() {
  if have_cmd unzip; then
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
  local tmp_err rc=0
  tmp_err="$(mktemp)"
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    apt-get install -y unzip 1>/dev/null 2>"$tmp_err" || rc=$?
  elif have_cmd sudo; then
    sudo apt-get install -y unzip 1>/dev/null 2>"$tmp_err" || rc=$?
  else
    log_line "ERROR" "Cannot install unzip: not root and sudo not available"
    echo "Need root privileges to install 'unzip'. See log: $LOG_FILE"
    rm -f "$tmp_err"
    return 1
  fi
  capture_and_log_stderr "apt-get install unzip" "$tmp_err"

  if [ $rc -ne 0 ] || ! have_cmd unzip; then
    log_line "ERROR" "unzip not found after apt-get install"
    echo "'unzip' installation failed. See log: $LOG_FILE"
    return 1
  fi

  local uv
  uv="$(installed_unzip_version || true)"
  if [ -n "$uv" ]; then
    echo "'unzip' installed successfully. Version: ${uv}"
  else
    echo "'unzip' installed successfully."
  fi

  # Usually unzip is in /usr/bin; if not in PATH for some reason, add it for this session
  local unzip_path
  unzip_path=$(dirname "$(command -v unzip)")
  if ! printf "%s" "$PATH" | tr ':' '\n' | grep -qx "$unzip_path"; then
    export PATH="$unzip_path:$PATH"
    echo "Note: $unzip_path was not in your PATH. Added for current session."
    echo "To make it permanent, add this to your shell profile:"
    echo "  export PATH=\"$unzip_path:\$PATH\""
  fi
  return 0
}

# -------- Terraform helpers --------
installed_tf_version() {
  local out ver
  if have_cmd terraform; then
    out=$(terraform version -json 2>/dev/null) || true
    if [ -n "$out" ]; then
      ver=$(printf "%s\n" "$out" | awk '
        match($0, /"terraform_version"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"/) {
          s=substr($0, RSTART, RLENGTH)
          sub(/.*:[[:space:]]*"/, "", s)
          sub(/"$/, "", s)
          print s; exit 0
        }')
      [ -n "$ver" ] && { printf "%s" "$ver"; return 0; }
    fi
    ver=$(terraform version 2>/dev/null | head -n1 | sed -n 's/.* v\([0-9]\+\.[0-9]\+\.[0-9]\+\).*/\1/p')
    [ -n "$ver" ] && { printf "%s" "$ver"; return 0; }
  fi
  return 1
}

version_lt() {
  local a="${1#v}" b="${2#v}"
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

# Attempt install to /usr/local/bin (using sudo if needed), else fall back to ~/.local/bin
install_binary_to_path() {
  # Args: <source_file> <preferred_dest_basename>
  local src="$1" name="$2" tmp_err rc=0
  local final_dir=""

  # Primary target: /usr/local/bin
  if [ -d "/usr/local/bin" ]; then
    if [ -w "/usr/local/bin" ]; then
      tmp_err="$(mktemp)"
      mv "$src" "/usr/local/bin/$name" 2>"$tmp_err" || rc=$?
      capture_and_log_stderr "move" "$tmp_err"
      if [ $rc -eq 0 ]; then
        final_dir="/usr/local/bin"
      fi
    elif have_cmd sudo; then
      tmp_err="$(mktemp)"
      sudo mv "$src" "/usr/local/bin/$name" 2>"$tmp_err" || rc=$?
      capture_and_log_stderr "sudo move" "$tmp_err"
      if [ $rc -eq 0 ]; then
        final_dir="/usr/local/bin"
      fi
    fi
  fi

  # Fallback target: ~/.local/bin
  if [ -z "$final_dir" ]; then
    local fallback="${HOME}/.local/bin"
    mkdir -p "$fallback" 2>/dev/null || true
    tmp_err="$(mktemp)"
    mv "$src" "${fallback}/$name" 2>"$tmp_err" || rc=$?
    capture_and_log_stderr "move" "$tmp_err"
    if [ $rc -ne 0 ]; then
      log_line "ERROR" "Failed to install binary into ${fallback}"
      echo "Install failed. See log: $LOG_FILE"
      return 1
    fi
    final_dir="$fallback"
  fi

  chmod +x "${final_dir}/$name" || true

  # If fallback dir not in PATH, add for current session and instruct for permanence
  if ! printf "%s" "$PATH" | tr ':' '\n' | grep -qx "$final_dir"; then
    export PATH="$final_dir:$PATH"
    echo "Note: $final_dir was not in your PATH. Added for current session."
    echo "To make it permanent, add this to your shell profile:"
    echo "  export PATH=\"$final_dir:\$PATH\""
  fi

  echo "$final_dir"   # return the dir used via stdout
  return 0
}

download_and_install_tf() {
  local latest os arch url tmpdir zipfile tmp_err rc=0 inst_dir

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
  tmp_err="$(mktemp)"
  curl -fSL "$url" -o "$zipfile" 1>/dev/null 2>"$tmp_err" || rc=$?
  capture_and_log_stderr "curl download" "$tmp_err"
  if [ $rc -ne 0 ]; then
    log_line "ERROR" "Failed to download ${url}"
    echo "Download failed. See log: $LOG_FILE"
    rm -rf "$tmpdir"
    return 1
  fi

  # Unzip
  tmp_err="$(mktemp)"
  (cd "$tmpdir" && unzip -o "$zipfile" 1>/dev/null 2>"$tmp_err") || rc=$?
  capture_and_log_stderr "unzip" "$tmp_err"
  if [ $rc -ne 0 ] || [ ! -f "${tmpdir}/terraform" ]; then
    log_line "ERROR" "Failed to unzip Terraform archive"
    echo "Extraction failed. See log: $LOG_FILE"
    rm -rf "$tmpdir"
    return 1
  fi

  # Install binary (prefers /usr/local/bin with sudo; fallback ~/.local/bin)
  inst_dir="$(install_binary_to_path "${tmpdir}/terraform" "terraform")" || {
    rm -rf "$tmpdir"
    return 1
  }

  rm -rf "$tmpdir"
  echo "Terraform ${latest} installed to ${inst_dir}/terraform"
}

# ---------------- MAIN ----------------
main() {
  if have_cmd terraform; then
    local installed latest
    installed=$(installed_tf_version || true)
    if [ -n "$installed" ]; then
      echo "Terraform is already present. Installed version: ${installed}"
    else
      echo "Terraform is present but version parsing failed."
    fi

    latest=$(get_latest_version || true)
    if [ -z "$latest" ]; then
      echo "Could not determine latest Terraform version. See log: $LOG_FILE"
      exit 0
    fi

    if [ -n "$installed" ] && version_lt "$installed" "$latest"; then
      echo "A newer version is available: ${latest}. You can download the latest version."
    else
      echo "You have the latest version (${latest}) or a newer build."
    fi
  else
    echo "Terraform not found. Fetching latest version metadata…"
    local latest
    latest=$(get_latest_version)
    if [ $? -ne 0 ] || [ -z "$latest" ]; then
      echo "Failed to get latest version. See log: $LOG_FILE"
      exit 1
    fi

    if ! install_unzip_if_needed; then
      exit 1
    fi

    echo "Latest Terraform version is ${latest}. Downloading and installing…"
    download_and_install_tf "$latest" || exit 1
  fi
}

main "$@"
