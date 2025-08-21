#!/usr/bin/env bash
# Proxmox VE 8 -> 9 interactive upgrade helper

set -uo pipefail
LOGFILE="/root/pve8to9-upgrade.log"

# --- helpers ---------------------------------------------------------------

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root." >&2
    exit 1
  fi
}

log() { echo -e "[*] $*" | tee -a "$LOGFILE"; }
warn() { echo -e "[!] $*" | tee -a "$LOGFILE"; }
die()  { echo -e "[x] $*" | tee -a "$LOGFILE"; exit 1; }

ask() {
  local prompt="$1"
  local ans
  read -rp "$prompt [y/N]: " ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

run() {
  # run "description" "command..."
  local desc="$1"; shift
  log "$desc"
  ( set -o pipefail; "$@" 2>&1 | tee -a "$LOGFILE" )
  local rc=${PIPESTATUS[0]}
  if [[ $rc -ne 0 ]]; then
    warn "Command failed with exit code $rc"
    return $rc
  fi
}

pause() {
  read -rp ">>> Review output above. Press Enter to continue..." _
}

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  cp -a "$f" "${f}.bak.$(date +%F-%H%M%S)"
  log "Backed up $f to ${f}.bak.*"
}

ensure_keyring() {
  if [[ ! -f /usr/share/keyrings/proxmox-archive-keyring.gpg ]]; then
    run "Installing proxmox-archive-keyring..." apt-get update
    run "Install proxmox-archive-keyring" apt-get install -y proxmox-archive-keyring
  fi
}

# --- start -----------------------------------------------------------------

require_root
log "Logging to $LOGFILE"
echo "=== $(date) ===" >> "$LOGFILE"

# Step 1: Remove systemd-boot?
if ask "Step 1: Remove systemd-boot?"; then
  run "Removing systemd-boot (safe to skip if not installed)..." apt-get remove -y systemd-boot || true
fi

# Step 2: Install amd64-microcode?
if ask "Step 2: Install amd64-microcode (and add non-free-firmware)?"; then
  backup_file /etc/apt/sources.list
  run "Add non-free-firmware to /etc/apt/sources.list" \
    sed -i '/^deb/ {/non-free-firmware/! s/$/ non-free-firmware/ }' /etc/apt/sources.list
  run "apt update" apt-get update
  run "Install amd64-microcode" apt-get install -y amd64-microcode || true
fi

# Step 3: Install all available PVE 8 updates?
if ask "Step 3: Install all available PVE 8 updates?"; then
  run "apt update" apt-get update
  run "apt dist-upgrade" apt-get dist-upgrade -y
  run "Show PVE version" pveversion || true
fi

# Step 4: Run PVE upgrade checker
if ask "Step 4: Run PVE upgrade checker (pve8to9 --full)?"; then
  run "Running pve8to9 --full" pve8to9 --full || true
  pause
fi

# Step 5: Add update sources
if ask "Step 5: Add/adjust Debian & Proxmox sources for Trixie/PVE9?"; then
  ensure_keyring
  backup_file /etc/apt/sources.list
  run "Switch /etc/apt/sources.list bookworm->trixie" \
    sed -i 's/\bbookworm\b/trixie/g' /etc/apt/sources.list

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
  cat > /etc/apt/sources.list.d/proxmox.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
  log "Wrote /etc/apt/sources.list.d/proxmox.sources"

  run "apt update" apt-get update || true
fi

# Step 6: Run PVE upgrade checker again
if ask "Step 6: Run PVE upgrade checker again (pve8to9 --full)?"; then
  run "Running pve8to9 --full again" pve8to9 --full || true
  pause
fi

# Step 7: Upgrade to Debian Trixie & PVE 9
if ask "Step 7: Upgrade to Debian Trixie & PVE9?"; then
  run "apt update" apt-get update
  run "apt dist-upgrade -y" apt-get dist-upgrade -y
fi

# Step 8: Post-install checker
if ask "Step 8: Run post-install checker (pve8to9 --full)?"; then
  run "Running final pve8to9 --full" pve8to9 --full || true
  pause
fi

# Step 9: Modernize sources
if ask "Step 9: Modernize repository sources (apt modernize-sources)?"; then
  run "Modernize sources" apt-get modernize-sources || true
fi

# Step 10: Reboot
if ask "Step 10: Reboot now?"; then
  log "Rebooting..."
  reboot
else
  log "Upgrade complete. Please reboot manually later."
fi

log "All done. Full log: $LOGFILE"
