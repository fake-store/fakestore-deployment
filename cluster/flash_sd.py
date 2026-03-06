#!/usr/bin/env python3
"""Flash Raspberry Pi OS to SD cards for Kubernetes cluster (macOS)."""

import os
import sys
import re
import json
import time
import subprocess
import plistlib
import shutil
from dataclasses import dataclass
from typing import List, Optional
from pathlib import Path

# =========================
# Configuration
# =========================

PI_IMAGE = os.path.expanduser("~/Downloads/2025-12-04-raspios-trixie-arm64-lite.img")
SSH_KEY_NAME = "pi_cluster_key"

# =========================

ANSIBLE_INVENTORY_CMD = ""
DEBUG = True


def debug(*args, quiet: bool = False):
    """Print debug message if DEBUG is enabled (dim gray)."""
    if DEBUG and not quiet:
        msg = " ".join(str(a) for a in args)
        print(f"\033[90m[DEBUG] {msg}\033[0m")


def error(*args):
    """Print error message to stderr in red."""
    msg = " ".join(str(a) for a in args)
    print(f"\033[91m[ERROR] {msg}\033[0m", file=sys.stderr)


def warn(*args):
    """Print warning message in yellow."""
    msg = " ".join(str(a) for a in args)
    print(f"\033[93m[WARN] {msg}\033[0m")


def info(msg):
    """Print info message."""
    print(msg)


# =========================
# Data classes
# =========================

@dataclass
class DeviceInfo:
    """Information about a disk device."""
    path: str
    size: str
    media_type: str
    media_name: str


# =========================
# Shell command helper
# =========================

def run_command(cmd, capture_output=True, check=True, quiet=False):
    """Run a shell command, log output, and return result or raise exception."""
    print(f"Running: \033[91m{cmd}\033[0m")
    result = subprocess.run(cmd, shell=True, capture_output=capture_output, text=True, check=False)

    if capture_output:
        if result.stdout:
            debug(f"stdout: {result.stdout.strip()}", quiet=True)
        if result.stderr:
            debug(f"stderr: {result.stderr.strip()}")

    debug(f"Exit code: {result.returncode}")

    if check and result.returncode != 0:
        error(f"Command failed: {cmd}")
        if result.stderr:
            error(f"stderr: {result.stderr.strip()}")
        raise subprocess.CalledProcessError(result.returncode, cmd, result.stdout, result.stderr)

    return result


# =========================
# macOS Disk Operations
# =========================

_boot_part = None  # Track mounted boot partition for cleanup


def check_privileges():
    """Check if running as root (required for disk operations on macOS)."""
    if os.geteuid() != 0:
        raise PermissionError("This script must be run with root privileges (sudo).")
    debug("Root privileges confirmed.")


def _get_plist(device):
    """Get plist info for a device. Returns dict or None on failure."""
    try:
        result = run_command(f"diskutil info -plist {device}", check=False, quiet=True)
        if result.returncode != 0:
            return None
        return plistlib.loads(result.stdout.encode())
    except Exception:
        return None


def _get_device_info(device) -> Optional[DeviceInfo]:
    """Get device info. Returns DeviceInfo or None if internal."""
    plist = _get_plist(device)
    if not plist:
        return None

    if plist.get("Internal", False):
        return None

    size_bytes = plist.get("TotalSize", 0)
    size = f"{size_bytes / (1024 ** 3):.1f} GB" if size_bytes else "Unknown"

    return DeviceInfo(
        path=device,
        size=size,
        media_type=plist.get("MediaType", "Unknown"),
        media_name=plist.get("MediaName", "Unknown")
    )


def _is_device_mounted(device) -> bool:
    """Check if device or any of its partitions are mounted."""
    plist = _get_plist(device)
    if not plist:
        return False
    if plist.get("MountPoint"):
        return True
    for i in range(1, 3):
        part_plist = _get_plist(f"{device}s{i}")
        if part_plist and part_plist.get("MountPoint"):
            return True
    return False


def _unmount_disk(device, timeout=10):
    """Attempt to unmount entire disk and partitions, wait until unmounted."""
    run_command(f"diskutil unmountDisk {device}", check=False)
    run_command(f"diskutil unmount {device}s1", check=False)
    run_command(f"diskutil unmount {device}s2", check=False)

    elapsed = 0
    while _is_device_mounted(device) and elapsed < timeout:
        debug(f"Device {device} still mounted, waiting...")
        time.sleep(0.5)
        elapsed += 0.5

    if _is_device_mounted(device):
        warn(f"Device {device} still mounted after {timeout} seconds")
        return False

    debug(f"Device {device} unmounted successfully")
    return True


def _wait_for_device(device, timeout=10) -> bool:
    """Wait for device to be available."""
    info(f"Waiting for {device} to be available...")
    elapsed = 0
    while elapsed < timeout:
        if os.path.exists(device):
            info(f"Device {device} found.")
            return True
        time.sleep(1)
        elapsed += 1
    error(f"Device {device} not found after {timeout} seconds.")
    return False


def _mount_boot_partition(device, mount_point):
    """Mount the boot partition. Returns the boot partition path."""
    boot_part = f"{device}s1"
    os.makedirs(mount_point, exist_ok=True)
    try:
        run_command(f"mount -t msdos {boot_part} {mount_point}")
        debug(f"Mounted {boot_part} at {mount_point}")
        return boot_part
    except subprocess.CalledProcessError as e:
        error(f"Mount failed: {e.stderr if e.stderr else e}")
        try:
            os.rmdir(mount_point)
        except Exception:
            pass
        raise


def _unmount_partition(boot_part, mount_point):
    """Unmount the partition and remove the mount point."""
    try:
        run_command(f"diskutil unmount {boot_part}", check=False)
    except Exception:
        try:
            run_command(f"umount {mount_point}", check=False)
        except Exception:
            pass

    try:
        os.rmdir(mount_point)
    except OSError:
        try:
            shutil.rmtree(mount_point)
        except Exception as e:
            warn(f"Failed to remove mount point {mount_point}: {e}")


def get_external_devices() -> List[DeviceInfo]:
    """Get list of external disk devices."""
    result = run_command("diskutil list -plist", quiet=True)
    plist = plistlib.loads(result.stdout.encode())
    all_devices = plist.get("AllDisks", [])
    whole_disks = [f"/dev/{d}" for d in all_devices if re.match(r'^disk\d+$', d)]
    whole_disks = list(dict.fromkeys(whole_disks))

    devices = []
    for dev in whole_disks:
        info = _get_device_info(dev)
        if info:
            devices.append(info)
    return devices


def flash_device(device: str, image_path: str):
    """Write image to device using dd."""
    _unmount_disk(device)
    if not _wait_for_device(device):
        raise FileNotFoundError(f"Device {device} not available for flashing.")

    info(f"Flashing {image_path} to {device}...")
    cmd = f"dd if={image_path} of={device} bs=4M"
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if result.stderr:
        print(result.stderr)
    if result.stdout:
        print(result.stdout)
    if result.returncode != 0:
        warn(f"dd exited with code {result.returncode}")
        if "Operation not permitted" in (result.stderr or ""):
            error("macOS Full Disk Access required.")
            # Go to System Settings > Privacy & Security > Full Disk Access and add your terminal app, or run this script outside the IDE.
        raise subprocess.CalledProcessError(result.returncode, cmd)


def prepare_boot_partition(device: str, mount_point: str) -> bool:
    """Prepare boot partition for writing config files."""
    global _boot_part

    if not _wait_for_device(device):
        error(f"Device {device} not available")
        return False

    _unmount_disk(device)

    try:
        _boot_part = _mount_boot_partition(device, mount_point)
        return True
    except subprocess.CalledProcessError:
        error(f"Failed to mount boot partition on {device}")
        return False


def finalize_boot_partition(device: str, mount_point: str):
    """Finalize boot partition after writing config files (unmount and cleanup)."""
    global _boot_part

    if _boot_part is None:
        # nothing to do
        return

    boot = _boot_part
    # Clear tracker immediately to avoid stale state if unmount fails
    _boot_part = None

    try:
        _unmount_partition(boot, mount_point)
    except Exception as e:
        warn(f"Failed to unmount partition during finalize: {e}")


# =========================
# Secrets and Configuration
# =========================

def load_secrets(secrets_file_path):
    """Load secrets from secrets.json file into global cache."""
    # load json
    debug(f"Loading secrets from file: {secrets_file_path}")
    if not os.path.exists(secrets_file_path):
        raise FileNotFoundError(f"Secrets file not found at {secrets_file_path}")
    with open(secrets_file_path, "r") as f:
        secrets_json = json.load(f)

    # VALIDATE
    has_error = False
    if not secrets_json.get("default_user"):
        error("default_user not found in secrets.json")
        has_error = True
    if not secrets_json.get("default_password"):
        error("default_password not found in secrets.json")
        has_error = True
    if has_error:
        raise ValueError("secrets.json is missing required fields.")

    debug("Secrets loaded.")
    return secrets_json


def check_pi_image_exists():
    """Ensure the image file exists."""
    if not os.path.isfile(PI_IMAGE):
        raise FileNotFoundError(f"Raspberry Pi OS image not found at {PI_IMAGE}. Please download it first.")
    debug(f"Raspberry Pi OS image found at {PI_IMAGE}.")


# =========================
# Inventory
# =========================

def load_hosts(inventory_path):
    """Attempt to run `ansible-inventory --list -i INVENTORY` and return parsed JSON or None."""
    """Read hosts from inventory using ansible-inventory only. Returns list of (name, ip) tuples."""
    inv = ""
    try:
        ai_cmd = shutil.which('ansible-inventory')
        if not ai_cmd:
            # throw error
            raise FileNotFoundError(f"Ansible Inventory not found on path")

        p = subprocess.run([ai_cmd, '--list', '-i', str(inventory_path)], stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, text=True, check=False)
        if p.returncode != 0:
            return None
        inv = json.loads(p.stdout)
    except Exception:
        return None

    if not inv:
        error(
            'ansible-inventory not available or failed; please install ansible and ensure ansible-inventory is on PATH')
        sys.exit(4)

    hosts = []
    hostvars = inv.get('_meta', {}).get('hostvars', {})
    pis = inv.get('pis', {}).get('hosts', [])
    if pis:
        for name in pis:
            ip = hostvars.get(name, {}).get('ansible_host')
            if ip:
                hosts.append((name, ip))
    else:
        for name, hv in hostvars.items():
            ip = hv.get('ansible_host')
            if ip:
                hosts.append((name, ip))

    debug(f"Inventory hosts (via ansible-inventory): {hosts}")
    return hosts


# =========================
# Device Selection
# =========================

def list_devices():
    """List available disk devices with info. Returns list of device paths."""
    devices = get_external_devices()
    if not devices:
        print("No external disk devices found. Please insert an SD card and rescan (0).")
        return []
    print("Available devices:")
    for j, dev in enumerate(devices, 1):
        print(f"  {j}) {dev.path} - {dev.media_name} - {dev.media_type} - {dev.size}")
    return [dev.path for dev in devices]


def select_device_to_flash():
    """Prompt user to select a device."""
    devices = list_devices()

    while True:
        try:
            num = int(input("Select device number (0 to rescan): "))
            if num == 0:
                devices = list_devices()
                continue
            if 1 <= num <= len(devices):
                debug(f"Selected device {devices[num - 1]}")
                return devices[num - 1]
            else:
                print("Invalid selection.")
        except ValueError:
            print("Invalid input.")


# =========================
# Boot Partition Configuration
# =========================

def configure_cmdline(cmdline_path, ip, name):
    """Configure cmdline.txt with static IP."""
    if os.path.exists(cmdline_path):
        with open(cmdline_path, "r") as f:
            cmdline = f.read().strip()

        # Add static IP
        cmdline += f" ip={ip}::192.168.0.1:255.255.255.0:{name}:eth0:off"

        with open(cmdline_path, "w") as f:
            f.write(cmdline)
        info(f"Configured cmdline.txt with static IP {ip}.")
    else:
        warn(f"{cmdline_path} not found; skipping cmdline configuration.")


def enable_ssh(mount_point):
    """Create the ssh file in the boot partition to enable SSH."""
    ssh_path = os.path.join(mount_point, "ssh")
    try:
        with open(ssh_path, "w"):
            pass
        info("Created SSH enable file.")
    except Exception as e:
        warn(f"Failed to create SSH enable file: {e}")


def create_user(userconf_path, username, password):
    """Create userconf.txt with hashed password for default user setup."""
    try:
        # Use openssl to generate proper crypt(3) SHA-512 hash
        result = subprocess.run(
            ["openssl", "passwd", "-6", password],
            capture_output=True, text=True, check=True
        )
        crypt_hash = result.stdout.strip()
        with open(userconf_path, "w") as f:
            f.write(f"{username}:{crypt_hash}\n")
        info(f"Created userconf.txt for user '{username}'.")
    except Exception as e:
        warn(f"Failed to create userconf.txt: {e}")


def create_firstrun_script(firstrun_path, host_name, user_name, ssh_pubkey):
    """Create firstrun.sh script for first-boot configuration."""

    script_lines = [
        "#!/bin/bash",
        "set +e",
        "",
        "# Set hostname",
        f"HOSTNAME='{host_name}'",
        'echo "$HOSTNAME" > /etc/hostname',
        'sed -i "s/127.0.1.1.*$/127.0.1.1\\t$HOSTNAME/" /etc/hosts',
        "",
        "# Enable SSH",
        "systemctl enable ssh",
        "systemctl start ssh",
        "",
        f"# Setup SSH authorized_keys for {user_name} user",
        f"USER_HOME=/home/{user_name}",
        "mkdir -p $USER_HOME/.ssh",
        "chmod 700 $USER_HOME/.ssh",
        f"echo '{ssh_pubkey}' >> $USER_HOME/.ssh/authorized_keys",
        "chmod 600 $USER_HOME/.ssh/authorized_keys",
        f"chown -R {user_name}:{user_name} $USER_HOME/.ssh",
        "",
        "# Install dependencies",
        "apt update",
        "apt install -y apt-transport-https ca-certificates curl gnupg lsb-release",
        "",
        "# Disable swap (kubernetes requirement)",
        "swapoff -a || true",
        "sed -i.bak '/\\sswap\\s/Id' /etc/fstab || true",
        "",
        "# Ensure kernel modules required by container runtimes are loaded",
        "cat > /etc/modules-load.d/k8s.conf <<'EOF'\noverlay\nbr_netfilter\nEOF",
        "modprobe overlay || true",
        "modprobe br_netfilter || true",
        "",
        "# Set sysctl params for Kubernetes networking",
        "cat > /etc/sysctl.d/k8s.conf <<'EOF'\nnet.bridge.bridge-nf-call-iptables=1\nnet.bridge.bridge-nf-call-ip6tables=1\nnet.ipv4.ip_forward=1\nEOF",
        "sysctl --system || true",
        "",
        "# Remove this script after first run",
        "rm -f /boot/firmware/firstrun.sh",
        "sed -i 's| systemd.run.*||g' /boot/firmware/cmdline.txt",
        "",
        "# Mark completion so playbooks can detect firstboot happened",
        "mkdir -p /var/lib/firstboot && touch /var/lib/firstboot/boot-configured",
        "",
        "exit 0",
    ]

    try:
        with open(firstrun_path, "w") as f:
            f.write("\n".join(script_lines))
        os.chmod(firstrun_path, 0o755)
        info(f"Created firstrun.sh for hostname '{host_name}'.")
    except Exception as e:
        warn(f"Failed to create firstrun.sh: {e}")


def add_firstrun_to_cmdline(mount_point):
    """Add firstrun.sh invocation to cmdline.txt."""
    cmdline_path = os.path.join(mount_point, "cmdline.txt")
    if not os.path.exists(cmdline_path):
        warn(f"{cmdline_path} not found; skipping firstrun hook.")
        return

    try:
        with open(cmdline_path, "r") as f:
            cmdline = f.read().strip()

        firstrun_hook = " systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target"

        if "systemd.run=" not in cmdline:
            cmdline += firstrun_hook
            with open(cmdline_path, "w") as f:
                f.write(cmdline)
            info("Added firstrun.sh hook to cmdline.txt.")
    except Exception as e:
        warn(f"Failed to modify cmdline.txt: {e}")


def configure_boot_partition(device, host_name, host_ip, secrets_json, ssh_pubkey):
    """Configure boot partition with user, SSH, hostname settings."""
    mount_point = f"/tmp/pi_boot_{host_name}"

    if not prepare_boot_partition(device, mount_point):
        return False

    info(f"Configuring boot partition for {host_name}")
    create_user(
        os.path.join(mount_point, "userconf.txt"),
        secrets_json.get("default_user"),
        secrets_json.get("default_password")
    )
    enable_ssh(mount_point)
    create_firstrun_script(
        os.path.join(mount_point, "firstrun.sh"),
        host_name,
        secrets_json.get("default_user"),
        ssh_pubkey
    )
    configure_cmdline(
        os.path.join(mount_point, "cmdline.txt"),
        host_ip,
        host_name
    )
    add_firstrun_to_cmdline(mount_point)
    finalize_boot_partition(device, mount_point)
    return True


def get_ssh_pubkey_path(key_name):
    ssh_key_path = os.path.expanduser(f"~/.ssh/{key_name}")
    ssh_pubkey_path = os.path.expanduser(f"~/.ssh/{key_name}.pub")
    if os.path.exists(ssh_pubkey_path):
        return ssh_pubkey_path

    # Interactive prompt: generate or abort
    try:
        print(f"key [{key_name}] not found, press Enter to generate, or Ctrl-C to exit")
        input()
    except KeyboardInterrupt:
        error('SSH key generation aborted by user')
        sys.exit(1)

    # generate the key
    try:
        run_command(f"ssh-keygen -t ed25519 -f {ssh_key_path} -N '' -C '{key_name}'", check=True, )
        info(f"SSH key pair generated at {ssh_key_path} and {ssh_pubkey_path}.")
        return ssh_pubkey_path
    except Exception as e:
        error('Failed to generate SSH key:', e)
        print(
            f"\nYou can also generate one manually with:\n  ssh-keygen -t ed25519 -f {ssh_key_path} -N \"\" -C \"{key_name}\"\n")
        sys.exit(1)


def load_ssh_pubkey_file(key_name):
    """Check SSH key pair exists and load it. Wipes known hosts for cluster nodes."""
    ssh_pubkey_path = get_ssh_pubkey_path(key_name)

    # Read and cache the public key
    with open(ssh_pubkey_path, "r") as f:
        key = f.read().strip()

    # validate key format
    if not re.match(r'^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256) [A-Za-z0-9+/=]+(?: .+)?$', key):
        error("SSH public key format invalid.")
        raise ValueError("SSH public key format invalid.")

    debug("SSH public key loaded from key file.")
    return key


def check_ansible_available():
    global ANSIBLE_INVENTORY_CMD
    ANSIBLE_INVENTORY_CMD = shutil.which('ansible-inventory')
    if not ANSIBLE_INVENTORY_CMD:
        # error('Ansible inventory not found. Please install Ansible and try again.')
        raise FileNotFoundError('"ansible-inventory" command not found. Please install Ansible and try again.')
    debug('Ansible inventory command found.')


# =========================
# Main
# =========================

def main():
    root = Path(__file__).parent

    try:
        check_privileges()  # ensure sudo
        check_pi_image_exists()  # ensure pi image exists
        check_ansible_available()  # ensure ansible is installed
        secrets_json = load_secrets(root / "secrets.json")
        hosts = load_hosts(root / 'inventory.ini')
        ssh_pubkey = load_ssh_pubkey_file(SSH_KEY_NAME)
    except Exception as e:
        error(f"Initialization failed:\n{e}")
        sys.exit(1)

    for host_name, host_ip in hosts:
        try:
            print("=============================")
            print(f"Insert SD card for {host_name} ({host_ip})")
            # beep
            response = input("Press Enter to flash, or 's' to skip: ").strip().lower()
            if response == 's':
                print(f"Skipping {host_name}.")
                continue
            device = select_device_to_flash()
            flash_device(device, PI_IMAGE)
            configure_boot_partition(device, host_name, host_ip, secrets_json, ssh_pubkey)
            print(f"SD card for {host_name} ready.")
        except Exception as e:
            error(f"Error flashing card for {host_name}: {e}")
            continue
    print("=============================")
    print("All SD cards flashed and configured.")

    # Informational next steps for the user
    print("")
    print("Next steps:")
    print("  1) Insert the SD cards into their Pis and boot them.")
    print("  -  Wait a few minutes for first boot configuration to complete.")
    print("  2) From your control machine run the cluster setup playbook:")
    print("       python3 k3s_setup.py setup")
    print("       python3 seed_known_hosts.py")
    print("  3) Then validate the cluster and deploy tests:")
    print("       python3 k3s_setup.py diag")
    print("       python3 k3s_setup.py test")
    print("")


if __name__ == "__main__":
    main()
