cat >/root/pve8to9-interactive.sh <<'SCRIPT_END'
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
  local q ans
  q="$1"
  read -rp "$q [y/N]: " ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

pause_review() {
  echo
  read -rp ">>> Review the output above. Press Enter to continue..." _
}

backup_file() {
  local f b
  f="$1"
  [[ -f "$f" ]] || return 0
  b="${f}.bak.$(date +%F-%H%M%S)"
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
  local desc rc
  desc="$1"; shift
  log "$desc"
  ( set -o pipefail; "$@" 2>&1 | tee -a "$LOGFILE" )
  rc=${PIPESTATUS[0]}
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
  log "Starting Proxmox 8 -> 9 interactive upgrade"
fi

# ------------------------- Resume path only -------------------------
if [[ "$RESUME_MODE" -eq 1 ]]; then
  # Step 9: Modernize repository sources (only if supported)
  if ask "Step 9: Modernize repository sources (apt modernize-sources)?"; then
    if apt -o APT::Cmd::Disable-Script-Warning=true help 2>/dev/null | grep -q "modernize-sources"; then
      run "Modernize sources" apt modernize-sources || true
    else
      warn "APT $(apt -v | head -n1) does not support 'modernize-sources'; skipping."
    fi
  else
    log "Skipped Step 9."
  fi

  # Step 10: Final reboot
  if ask "Step 10: Reboot now to complete the upgrade?"; then
    log "Final reboot at user request."
    rm -f "$RESUME_MARK"
    reboot
    exit 0
  else
    log "All done. You can reboot later at your convenience."
    rm -f "$RESUME_MARK"
    exit 0
  fi
fi

# ------------------------- Normal flow (Steps 1–8) -------------------------

# Step 1: Remove systemd-boot?
if ask "Step 1: Remove systemd-boot?"; then
  run "Removing systemd-boot (ok if not installed)..." apt-get remove -y systemd-boot || true
else
  log "Skipped Step 1."
fi

# Step 2: Install amd64-microcode and add non-free-firmware
if ask "Step 2: Install amd64-microcode (and add 'non-free-firmware' to Debian repos)?"; then
  if [[ -f /etc/apt/sources.list ]]; then
    backup_file /etc/apt/sources.list
    run "Adding 'non-free-firmware' to active deb lines" \
      sed -i '/^deb/ {/non-free-firmware/! s/$/ non-free-firmware/ }' /etc/apt/sources.list
  fi
  run "apt update" apt-get update
  run "Install amd64-microcode" apt-get install -y amd64-microcode || true
else
  log "Skipped Step 2."
fi

# Step 3: Install all available PVE 8 updates
if ask "Step 3: Install all available PVE 8 updates?"; then
  run "apt update" apt-get update
  run "apt dist-upgrade -y" apt-get dist-upgrade -y
  run "Show PVE version" pveversion || true
else
  log "Skipped Step 3."
fi

# Step 4: Run PVE upgrade checker (REVIEW)
if ask "Step 4: Run PVE upgrade checker (pve8to9 --full)?"; then
  run "Running pve8to9 --full (pre-switch)" pve8to9 --full || true
  pause_review
else
  log "Skipped Step 4."
fi

# Step 5: Add/update sources for Trixie & PVE9
if ask "Step 5: Add/adjust Debian & Proxmox sources for Trixie/PVE9?"; then
  ensure_keyring
  if [[ -f /etc/apt/sources.list ]]; then
    backup_file /etc/apt/sources.list
    run "Switch /etc/apt/sources.list bookworm->trixie" \
      sed -i 's/\bbookworm\b/trixie/g' /etc/apt/sources.list
  fi
  if [[ -f /etc/apt/sources.list.d/pve-install-repo.list ]]; then
    backup_file /etc/apt/sources.list.d/pve-install-repo.list
    : > /etc/apt/sources.list.d/pve-install-repo.list
    log "Emptied /etc/apt/sources.list.d/pve-install-repo.list"
  fi
  if [[ -f /etc/apt/sources.list.d/pve-enterprise.list ]]; then
    backup_file /etc/apt/sources.list.d/pve-enterprise.list
    run "Switch pve-enterprise.list bookworm->trixie" \
      sed -i 's/\bbookworm\b/trixie/g' /etc/apt/sources.list.d/pve-enterprise.list
  fi
  backup_file /etc/apt/sources.list.d/proxmox.sources || true
  cat > /etc/apt/sources.list.d/proxmox.sources <<'EOF_PVE'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF_PVE
  log "Wrote /etc/apt/sources.list.d/proxmox.sources"
  run "apt update" apt-get update || true
else
  log "Skipped Step 5."
fi

# Step 6: Run PVE upgrade checker again (REVIEW)
if ask "Step 6: Run PVE upgrade checker again (pve8to9 --full)?"; then
  run "Running pve8to9 --full (post-sources)" pve8to9 --full || true
  pause_review
else
  log "Skipped Step 6."
fi

# Step 7: Upgrade to Debian Trixie & PVE9
if ask "Step 7: Upgrade to Debian Trixie & PVE9?"; then
  run "apt update" apt-get update
  run "apt dist-upgrade -y" apt-get dist-upgrade -y
else
  log "Skipped Step 7."
fi

# Step 8: Post-install checker (REVIEW) -> create marker and reboot (or remind)
if ask "Step 8: Run post-install checker (pve8to9 --full)?"; then
  run "Running final pve8to9 --full" pve8to9 --full || true
  pause_review
else
  log "Skipped Step 8."
fi

echo
if ask "Reboot now to continue with Step 9 on the upgraded system (recommended)?"; then
  log "Creating resume marker at $RESUME_MARK and rebooting..."
  : > "$RESUME_MARK"
  sync
  reboot
  exit 0
else
  warn "Please reboot before Step 9. When the node is back, re-run this script to resume at Step 9."
  log "Creating resume marker at $RESUME_MARK (manual reboot pending)"
  : > "$RESUME_MARK"
  sync
  exit 0
fi
SCRIPT_END
