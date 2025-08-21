#!/usr/bin/env bash
# Proxmox VE 8 -> 9 interactive upgrade helper (whiptail UI)
# Prompts before each step; logs everything and shows review screens at steps 4, 6, and 8.

set -uo pipefail

TITLE="Proxmox 8 → 9 Upgrade"
LOGFILE="/root/pve8to9-upgrade.log"

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

ensure_whiptail() {
  if ! command -v whiptail >/dev/null 2>&1; then
    apt-get update
    apt-get install -y whiptail
  fi
}

ask_yesno() {
  # ask_yesno "Title" "Message"
  local t="$1" m="$2"
  whiptail --title "$t" --yesno "$m" 12 78
}

msgbox() {
  # msgbox "Title" "Message"
  local t="$1" m="$2"
  whiptail --title "$t" --msgbox "$m" 12 78
}

textbox() {
  # textbox "Title" "/path/to/file"
  local t="$1" f="$2"
  whiptail --title "$t" --textbox "$f" 25 100
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

# Run a multi-line block, capture output to temp + log
run_block() {
  # run_block "Description" [review=yes|no]
  local desc="$1"; local review="${2:-no}"
  local tmp_script; tmp_script="$(mktemp)"
  local tmp_out;    tmp_out="$(mktemp)"
  cat >"$tmp_script"
  log "$desc"
  # shellcheck disable=SC1090
  ( set -o pipefail; bash "$tmp_script" ) > >(tee -a "$LOGFILE" "$tmp_out") 2>&1
  local rc=${PIPESTATUS[0]}
  rm -f "$tmp_script"
  if [[ "$review" == "yes" ]]; then
    # Show captured output in a scrollable textbox
    if [[ ! -s "$tmp_out" ]]; then echo "(no output)" > "$tmp_out"; fi
    textbox "$TITLE - Output Review" "$tmp_out"
    # Pause explicitly
    ask_yesno "$TITLE" "Proceed to the next step?" || { rm -f "$tmp_out"; return $rc; }
  else
    msgbox "$TITLE" "Step finished (exit code $rc).\n\nLog: $LOGFILE"
  fi
  rm -f "$tmp_out"
  return $rc
}

# ----------------------------- start ---------------------------------------

require_root
ensure_whiptail
touch "$LOGFILE" || { echo "Cannot write to $LOGFILE"; exit 1; }
stamp
msgbox "$TITLE" "This guided helper will ask before each step.\n\nAll output is logged to:\n$LOGFILE"

# Step 1
if ask_yesno "$TITLE - Step 1" "Remove systemd-boot?\n\nCommand:\napt remove systemd-boot -y"; then
  run_block "Step 1: Removing systemd-boot..." <<'EOF'
apt-get remove -y systemd-boot || true
EOF
fi

# Step 2
if ask_yesno "$TITLE - Step 2" "Install amd64-microcode and add 'non-free-firmware'?\n\nCommands:\nsed ... /etc/apt/sources.list\napt update\napt install amd64-microcode -y"; then
  run_block "Step 2: Add non-free-firmware + install microcode..." <<'EOF'
set -o pipefail
if [[ -f /etc/apt/sources.list ]]; then
  cp -a /etc/apt/sources.list "/etc/apt/sources.list.bak.$(date +%F-%H%M%S)"
  # Append non-free-firmware only to active 'deb' lines that don't already have it
  sed -i '/^deb/ {/non-free-firmware/! s/$/ non-free-firmware/ }' /etc/apt/sources.list
fi
apt-get update
apt-get install -y amd64-microcode || true
EOF
fi

# Step 3
if ask_yesno "$TITLE - Step 3" "Install all available PVE 8 updates?\n\nCommands:\napt update\napt dist-upgrade -y\npveversion"; then
  run_block "Step 3: Dist-upgrade on 8.x + show version..." <<'EOF'
apt-get update
apt-get dist-upgrade -y
pveversion || true
EOF
fi

# Step 4 (REVIEW)
if ask_yesno "$TITLE - Step 4" "Run PVE upgrade checker (pve8to9 --full)?\n\nThis step will show output for review before continuing."; then
  run_block "Step 4: pve8to9 --full (pre-switch)" yes <<'EOF'
pve8to9 --full || true
EOF
fi

# Step 5
if ask_yesno "$TITLE - Step 5" "Add/update sources for Debian Trixie & Proxmox 9?\n\nThis will:\n• Switch bookworm->trixie in /etc/apt/sources.list\n• Empty pve-install-repo.list (avoid dupes)\n• Update pve-enterprise.list (if exists)\n• Write deb822 /etc/apt/sources.list.d/proxmox.sources\n• apt update"; then
  run_block "Step 5: Adjust sources to Trixie + PVE9..." <<'EOF'
set -o pipefail
# Ensure keyring for Signed-By
if [[ ! -f /usr/share/keyrings/proxmox-archive-keyring.gpg ]]; then
  apt-get update
  apt-get install -y proxmox-archive-keyring
fi

# Debian sources
if [[ -f /etc/apt/sources.list ]]; then
  cp -a /etc/apt/sources.list "/etc/apt/sources.list.bak.$(date +%F-%H%M%S)"
  sed -i 's/\bbookworm\b/trixie/g' /etc/apt/sources.list
fi

# Proxmox legacy installer list: blank it to avoid duplicate stanzas
if [[ -f /etc/apt/sources.list.d/pve-install-repo.list ]]; then
  cp -a /etc/apt/sources.list.d/pve-install-repo.list "/etc/apt/sources.list.d/pve-install-repo.list.bak.$(date +%F-%H%M%S)"
  : > /etc/apt/sources.list.d/pve-install-repo.list
fi

# Enterprise list (if present)
if [[ -f /etc/apt/sources.list.d/pve-enterprise.list ]]; then
  cp -a /etc/apt/sources.list.d/pve-enterprise.list "/etc/apt/sources.list.d/pve-enterprise.list.bak.$(date +%F-%H%M%S)"
  sed -i 's/\bbookworm\b/trixie/g' /etc/apt/sources.list.d/pve-enterprise.list
fi

# Primary PVE 9 deb822 source (no-subscription)
cat > /etc/apt/sources.list.d/proxmox.sources <<'SRC'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
SRC

apt-get update || true
EOF
fi

# Step 6 (REVIEW)
if ask_yesno "$TITLE - Step 6" "Run PVE upgrade checker again (pve8to9 --full)?\n\nThis step will show output for review before continuing."; then
  run_block "Step 6: pve8to9 --full (post-sources)" yes <<'EOF'
pve8to9 --full || true
EOF
fi

# Step 7
if ask_yesno "$TITLE - Step 7" "Upgrade to Debian Trixie & Proxmox 9?\n\nCommands:\napt update\napt dist-upgrade -y"; then
  run_block "Step 7: Dist-upgrade to Trixie + PVE9..." <<'EOF'
apt-get update
apt-get dist-upgrade -y
EOF
fi

# Step 8 (REVIEW)
if ask_yesno "$TITLE - Step 8" "Run post-install checker (pve8to9 --full)?\n\nThis step will show output for review before continuing."; then
  run_block "Step 8: pve8to9 --full (post-upgrade)" yes <<'EOF'
pve8to9 --full || true
EOF
fi

# Step 9
if ask_yesno "$TITLE - Step 9" "Modernize repository sources (apt modernize-sources)?"; then
  run_block "Step 9: apt modernize-sources..." <<'EOF'
apt modernize-sources || true
EOF
fi

# Step 10
if ask_yesno "$TITLE - Step 10" "Reboot now?"; then
  log "Rebooting now at user request."
  msgbox "$TITLE" "Rebooting…\n\nLog saved to $LOGFILE"
  reboot
else
  msgbox "$TITLE" "All done.\n\nPlease reboot when convenient.\nLog: $LOGFILE"
fi

exit 0
