#!/usr/bin/env bash
# Proxmox VE 8 -> 9 interactive upgrade helper (simple marker resume)
# - Prompts Yes/No per step
# - Pauses after steps 4, 6, and 8 for review
# - After step 8, creates /root/pve-upgrade-state-9 and offers reboot
# - On next run, if marker exists, resume at Step 9
# - Logs to /root/pve8to9-upgrade.log

set -uo pipefail

LOGFILE="/root/pve8to9-upgrade.log"
RESUME_MARK="/root/pve-upgrade-state-9"

# ----------------------------- helpers -------------------------------------

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root." >&2
    exit 1
  fi
}

log()   { echo -e "[*] $*" | tee -a "$LOGFILE"; }
warn()  { echo -e "[!] $*" | tee -a "$LOGFILE"; }
stamp() { echo "=== $(date) ===" >> "$LOGFILE"; }

ask() {
  local q="$1" ans
  read -rp "$q [y/N]: " ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

pause_review() {
  echo
  read -rp ">>> Review the output above. Press Enter to continue..." _
}

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local b="${f}.bak.$(date +%F-%H%M%S)"
  cp -a "$f" "$b"
  log "Backed up $f to $b"
}

ensure_keyring() {
  if [[ ! -f /usr/share/keyrings/proxmox-archive-keyring.gpg ]]; then
    log "Installing proxmox-archive-keyring..."
    apt-get update
    apt-get install -y proxmox-archive-keyring
  fi
}

run() {
  local desc="$1"; shift
  log "$desc"
  ( set -o pipefail; "$@" 2>&1 | tee -a "$LOGFILE" )
  local rc=${PIPESTATUS[0]}
  if [[ $rc -ne 0 ]]; then
    warn "Command failed with exit code $rc"
  fi
  return $rc
}

# ----------------------------- start ---------------------------------------

require_root
touch "$LOGFILE" || { echo "Cannot write to $LOGFILE"; exit 1; }
stamp

if [[ -f "$RESUME_MARK" ]]; then
  log "Resume marker found ($RESUME_MARK). Resuming at Step 9..."
  RESUME_MODE=1
else
  RESUME_MODE=0
  log "Starting Proxmox 8 → 9 interactive upgrade"
fi

# ------------------------- Resume path only -------------------------
if [[ "$RESUME_MODE" -eq 1 ]]; then
  # Step 9: Modernize repository sources (only if supported)
  if ask "Step 9: Modernize repository sources (apt modernize-sources)?"; then
    if apt -o APT::Cmd::Disable-Script-Warning=true help 2>/dev/null | grep -q "modernize-s
