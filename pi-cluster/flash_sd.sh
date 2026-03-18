#!/usr/bin/env bash
# Flash Raspberry Pi OS to SD cards for the cluster (macOS).
# Must be run with sudo.
# Usage: sudo ./flash_sd.sh
set -euo pipefail

PI_IMAGE="${PI_IMAGE:-$HOME/Downloads/iso/2025-12-04-raspios-trixie-arm64-lite.img}"
TMP_IMAGE="/tmp/pi-cluster/$(basename "$PI_IMAGE")"
TMP_BOOT="/tmp/pi-cluster/boot"
SSH_KEY_NAME="pi_cluster_key"
SSH_KEY_PATH="$HOME/.ssh/$SSH_KEY_NAME"
SSH_PUBKEY_PATH="$HOME/.ssh/$SSH_KEY_NAME.pub"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INVENTORY="$SCRIPT_DIR/inventory.ini"

# ── Helpers ───────────────────────────────────────────────────────────────────

info()   { echo "$*"; }
detail() { echo "  - $*"; }
warn()   { echo "[WARN] $*"; }
error()  { echo "[ERROR] $*" >&2; }

require_macos() {
  if [ "$(uname)" != "Darwin" ]; then
    error "This script requires macOS (uses hdiutil, diskutil, /dev/rdisk)."
    exit 1
  fi
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    error "Must be run as root. Use: sudo $0"
    exit 1
  fi
}

# ── Image ─────────────────────────────────────────────────────────────────────

check_image() {
  if [ ! -f "$PI_IMAGE" ]; then
    error "Pi image not found at $PI_IMAGE"
    error "Set PI_IMAGE env var or place image at the default path."
    exit 1
  fi
}

# Copy base image to tmp location once; reuse on subsequent cards.
prepare_tmp_image() {
  info "prepare image"
  mkdir -p /tmp/pi-cluster
  if [ ! -f "$TMP_IMAGE" ]; then
    detail "copying image to $TMP_IMAGE"
    cp "$PI_IMAGE" "$TMP_IMAGE"
    detail "copy complete"
  else
    detail "image exists at $TMP_IMAGE"
  fi
}

# ── SSH key ───────────────────────────────────────────────────────────────────

load_ssh_pubkey() {
  info "ssh key"
  if [ ! -f "$SSH_PUBKEY_PATH" ]; then
    detail "key [$SSH_KEY_NAME] not found — press Enter to generate, Ctrl-C to abort"
    read -r
    ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "$SSH_KEY_NAME"
  fi
  SSH_PUBKEY=$(cat "$SSH_PUBKEY_PATH")
  detail "loaded $SSH_PUBKEY_PATH"
}

# ── Secrets ───────────────────────────────────────────────────────────────────

load_secrets() {
  local secrets_file="$SCRIPT_DIR/secrets.env"
  if [ ! -f "$secrets_file" ]; then
    error "secrets.env not found. Copy secrets.env.example and fill in all values."
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$secrets_file"
  if [ -z "${PI_USER:-}" ] || [ -z "${PI_PASSWORD:-}" ]; then
    error "PI_USER and PI_PASSWORD must be set in secrets.env"
    exit 1
  fi
}

# ── Inventory ─────────────────────────────────────────────────────────────────

parse_hosts() {
  awk '
    /^\[pis\]/ { in_section=1; next }
    /^\[/      { in_section=0; next }
    in_section && /ansible_host=/ {
      name = $1
      for (i=2; i<=NF; i++) {
        if ($i ~ /^ansible_host=/) {
          split($i, a, "=")
          print name " " a[2]
        }
      }
    }
  ' "$INVENTORY"
}

# ── Device selection ──────────────────────────────────────────────────────────

get_external_devices() {
  diskutil list external physical | awk '/^\/dev\/disk/ { print $1 }'
}

device_label() {
  local dev="$1" info name size
  info=$(diskutil info "$dev" 2>/dev/null || true)
  name=$(echo "$info" | awk '/Media Name:/ { $1=$2=""; print substr($0,3) }' | sed 's/^ *//')
  size=$(echo "$info" | awk '/Disk Size:/ { print $3, $4 }')
  printf "%s  —  %s  —  %s" "$dev" "$name" "$size"
}

arrow_select() {
  local items=("$@")
  local count=${#items[@]}
  local sel=0 i key seq

  for i in "${!items[@]}"; do
    if [ "$i" -eq "$sel" ]; then
      printf "  \033[7m %s \033[0m\n" "${items[$i]}" >/dev/tty
    else
      printf "    %s\n" "${items[$i]}" >/dev/tty
    fi
  done

  printf "\033[?25l" >/dev/tty
  while true; do
    printf "\033[%dA" "$count" >/dev/tty
    for i in "${!items[@]}"; do
      printf "\r\033[2K" >/dev/tty
      if [ "$i" -eq "$sel" ]; then
        printf "  \033[7m %s \033[0m\n" "${items[$i]}" >/dev/tty
      else
        printf "    %s\n" "${items[$i]}" >/dev/tty
      fi
    done

    IFS= read -r -s -n1 key </dev/tty
    if [[ "$key" == $'\x1b' ]]; then
      IFS= read -r -s -n2 -t 1 seq </dev/tty || true
      if [[ "$seq" == '[A' ]]; then
        [ "$sel" -gt 0 ] && sel=$((sel - 1))
      elif [[ "$seq" == '[B' ]]; then
        [ "$sel" -lt $((count - 1)) ] && sel=$((sel + 1))
      else
        printf "\033[?25h" >/dev/tty
        return
      fi
    elif [[ -z "$key" ]]; then
      break
    fi
  done

  printf "\033[?25h" >/dev/tty
  printf "\n" >/dev/tty
  printf "%s\n" "${items[$sel]}"
}

select_device() {
  local host_name="$1" host_ip="$2"
  while true; do
    local devs=() labels=() dev choice

    while IFS= read -r dev; do
      devs+=("$dev")
    done < <(get_external_devices)

    printf "\n============================\n" >/dev/tty
    printf "Flashing %s : %s\n\n" "$host_name" "$host_ip" >/dev/tty

    if [ ${#devs[@]} -eq 0 ]; then
      printf "[WARN] No external drives found. Insert SD card, then press Enter to rescan.\n" >/dev/tty
      read -r </dev/tty
      continue
    fi

    for dev in "${devs[@]}"; do
      labels+=("$(device_label "$dev")")
    done
    labels+=("[ rescan ]")

    printf "Select device to flash, or Esc to skip (%s)\n\n" "$host_name" >/dev/tty
    choice=$(arrow_select "${labels[@]}")

    [ "$choice" = "[ rescan ]" ] && continue

    if [ -z "$choice" ]; then
      return
    fi

    dev=$(printf "%s" "$choice" | awk '{ print $1 }')
    if [ -b "$dev" ]; then
      printf "\nFlash %s for %s? This will erase all data.\n" "$dev" "$host_name" >/dev/tty
      printf "Enter to confirm   Esc to go back   Ctrl-C to abort\n" >/dev/tty
      local confirm
      IFS= read -r -s -n1 confirm </dev/tty
      if [[ -z "$confirm" ]]; then
        printf "%s\n" "$dev"
        return
      fi
      if [[ "$confirm" == $'\x1b' ]]; then
        continue
      fi
    fi
    printf "[WARN] Device '%s' not found.\n" "$dev" >/dev/tty
  done
}

# ── Image configuration ───────────────────────────────────────────────────────

# Mount the boot partition of the temp image, write per-card config, detach.
# Strips previously written ip= and systemd.run= from cmdline.txt before rewriting.
configure_image() {
  local host_name="$1" host_ip="$2"
  local disk

  info "configure image for $host_name - $host_ip"

  detail "attaching image"
  disk=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$TMP_IMAGE" \
    | awk 'NR==1 { print $1 }')
  detail "mounting boot partition"
  mkdir -p "$TMP_BOOT"
  mount -t msdos "${disk}s1" "$TMP_BOOT"

  # userconf.txt — hashed password for default user
  detail "writing userconf.txt"
  local hash
  hash=$(openssl passwd -6 "$PI_PASSWORD")
  echo "${PI_USER}:${hash}" > "$TMP_BOOT/userconf.txt"

  # ssh enable file
  detail "writing ssh enable file"
  touch "$TMP_BOOT/ssh"

  # firstrun.sh — hostname, SSH key, kernel modules
  detail "writing firstrun.sh"
  cat > "$TMP_BOOT/firstrun.sh" <<FIRSTRUN
#!/bin/bash
set +e

HOSTNAME='$host_name'
echo "\$HOSTNAME" > /etc/hostname
sed -i "s/127.0.1.1.*\$/127.0.1.1\\\t\$HOSTNAME/" /etc/hosts

systemctl enable ssh
systemctl start ssh

USER_HOME=/home/$PI_USER
mkdir -p \$USER_HOME/.ssh
chmod 700 \$USER_HOME/.ssh
echo '$SSH_PUBKEY' >> \$USER_HOME/.ssh/authorized_keys
chmod 600 \$USER_HOME/.ssh/authorized_keys
chown -R $PI_USER:$PI_USER \$USER_HOME/.ssh

apt update
apt install -y apt-transport-https ca-certificates curl gnupg lsb-release

swapoff -a || true
sed -i.bak '/\sswap\s/Id' /etc/fstab || true

cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay || true
modprobe br_netfilter || true

cat > /etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF
sysctl --system || true

rm -f /boot/firmware/firstrun.sh
sed -i 's| systemd.run.*||g' /boot/firmware/cmdline.txt
mkdir -p /var/lib/firstboot && touch /var/lib/firstboot/boot-configured
exit 0
FIRSTRUN
  chmod 755 "$TMP_BOOT/firstrun.sh"

  # cmdline.txt — strip any previously written config, then append fresh
  detail "updating cmdline.txt"
  local cmdline
  cmdline=$(cat "$TMP_BOOT/cmdline.txt")
  cmdline=$(echo "$cmdline" | sed \
    -e 's/ ip=[^ ]*//g' \
    -e 's/ systemd\.run=[^ ]*//g' \
    -e 's/ systemd\.run_success_action=[^ ]*//g' \
    -e 's/ systemd\.unit=[^ ]*//g')
  cmdline="${cmdline} ip=${host_ip}::192.168.0.1:255.255.255.0:${host_name}:eth0:off"
  cmdline="${cmdline} systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target"
  echo "$cmdline" > "$TMP_BOOT/cmdline.txt"

  detail "unmounting"
  diskutil unmount "${disk}s1" 2>&1 | sed 's/^/  * /' || true
  rmdir "$TMP_BOOT" 2>/dev/null || true
  hdiutil detach "$disk" 2>&1 | sed 's/^/  * /' || true
  detail "done"
}

# ── Disk operations ───────────────────────────────────────────────────────────

unmount_disk() {
  local dev="$1"
  diskutil unmountDisk "$dev" 2>&1 | sed 's/^/  * /' || true
  diskutil unmount "${dev}s1" 2>&1 | sed 's/^/  * /' || true
  diskutil unmount "${dev}s2" 2>&1 | sed 's/^/  * /' || true
}

flash_device() {
  local dev="$1"
  local rdev="${dev/disk/rdisk}"
  info "write image to $dev"
  detail "unmounting $dev"
  unmount_disk "$dev"
  detail "writing to $rdev"
  dd if="$TMP_IMAGE" of="$rdev" bs=4m
  detail "done"
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  require_macos
  require_root
  check_image
  info "image: $PI_IMAGE"
  load_ssh_pubkey
  load_secrets
  prepare_tmp_image

  HOSTS=()
  while IFS= read -r line; do
    HOSTS+=("$line")
  done < <(parse_hosts)
  if [ ${#HOSTS[@]} -eq 0 ]; then
    error "No hosts found in $INVENTORY"
    exit 1
  fi

  for entry in "${HOSTS[@]}"; do
    host_name=$(echo "$entry" | awk '{print $1}')
    host_ip=$(echo "$entry" | awk '{print $2}')

    dev=$(select_device "$host_name" "$host_ip")
    if [ -z "$dev" ]; then
      info "Skipping $host_name."
      continue
    fi
    configure_image "$host_name" "$host_ip"
    flash_device "$dev"
    ssh-keygen -R "$host_ip" &>/dev/null || true
    info "sd card for $host_name ready"
  done

  echo ""
  echo "============================="
  echo "All SD cards flashed and configured."
  echo ""
  echo "Boot the cluster and wait for first-boot to complete (~5 min)."
  echo ""
  echo "When ready to continue, run:"
  echo "  ./cluster-init.sh"
}

main "$@"
