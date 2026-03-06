#!/usr/bin/env python3
"""Seed ~/.ssh/known_hosts by removing and re-adding keys for hosts from the project's inventory.

This script performs two actions for each host returned by `load_hosts()` in `flash_sd.py`:
  1) run `ssh-keygen -R <host>` to remove any existing known_hosts entries (handles hashed entries)
  2) run `ssh-keyscan <host>` and append the returned key line to ~/.ssh/known_hosts (unhashed)

Run this from the `cluster` directory (or from the repo root); it will look for `inventory.ini` next to this file.
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from typing import List, Tuple

# Reuse load_hosts implementation from flash_sd to stay consistent with inventory parsing
from flash_sd import load_hosts


KNOWN_HOSTS_PATH = Path("~/.ssh/known_hosts").expanduser()


def remove_known_host(entry: str) -> None:
    """Remove any known_hosts entry for `entry` using ssh-keygen -R (best-effort)."""
    keygen = shutil_which('ssh-keygen')
    if not keygen:
        print("ssh-keygen not found on PATH; cannot remove existing known_hosts entries", file=sys.stderr)
        return
    try:
        subprocess.run([keygen, '-R', str(entry)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    except Exception as e:
        print(f"Warning: ssh-keygen -R failed for {entry}: {e}", file=sys.stderr)


# Preferred host key types to store (ordered). Change if you want different algorithms.
PREFERRED_KEY_TYPES = ('ssh-ed25519',)


def fetch_host_key(entry: str) -> list:
    """Return list of host-key lines from ssh-keyscan for the given entry (unhashed), filtered by preferred types.
    Returns an empty list on failure."""
    keyscan = shutil_which('ssh-keyscan')
    if not keyscan:
        print("ssh-keyscan not found on PATH; cannot fetch host keys", file=sys.stderr)
        return []
    try:
        # use unhashed output so known_hosts lines start with the plain IP/hostname
        p = subprocess.run([keyscan, str(entry)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, check=False)
        raw_lines = (p.stdout or '').splitlines()
        # filter to preferred key types
        matched = []
        for ln in raw_lines:
            parts = ln.split()
            if len(parts) >= 2 and parts[1] in PREFERRED_KEY_TYPES:
                matched.append(ln)
        return matched
    except Exception as e:
        print(f"ssh-keyscan failed for {entry}: {e}", file=sys.stderr)
        return []


def shutil_which(name: str) -> str | None:
    """Wrapper for shutil.which without importing shutil repeatedly."""
    try:
        import shutil
        return shutil.which(name)
    except Exception:
        return None


def append_known_host_line(path: Path, line: str) -> None:
    try:
        with path.open('a', encoding='utf-8') as f:
            f.write(line + '\n')
    except Exception as e:
        print(f"Failed to append to {path}: {e}", file=sys.stderr)


def update_known_hosts(host_entries: List[Tuple[str, str]]) -> int:
    """Remove and re-add host keys for the supplied host_entries (list of (name, ip)).

    Returns the number of keys successfully added.
    """
    KNOWN_HOSTS_PATH.parent.mkdir(parents=True, exist_ok=True)
    added = 0

    try:
        with KNOWN_HOSTS_PATH.open('r', encoding='utf-8') as kf:
            existing = kf.read()
    except FileNotFoundError:
        existing = ''

    for host_name, host_ip in host_entries:
        host = host_ip or host_name
        if not host:
            # host is missing both values?
            continue

        print(f"Processing host: {host_name} ({host})")

        # remove old entries (safe for hashed entries)
        remove_known_host(host)
        remove_known_host(host_name)

        # Re-read current known_hosts after removal so we don't use a stale cache
        try:
            with KNOWN_HOSTS_PATH.open('r', encoding='utf-8') as kf:
                existing = kf.read()
        except FileNotFoundError:
            existing = ''

        # fetch fresh keys (possibly multiple lines filtered)
        lines = fetch_host_key(host)
        if not lines and host != host_name:
            lines = fetch_host_key(host_name)
        if not lines:
            print(f"No matching preferred keys fetched for {host}; skipping")
            continue

        # append the fetched keys
        for ln in lines:
            if ln not in existing:
                append_known_host_line(KNOWN_HOSTS_PATH, ln)
                existing += ln + '\n'
                print(f"Added key for {host}: {ln.split()[0]}")
                added += 1

    # ensure permissions
    try:
        os.chmod(KNOWN_HOSTS_PATH, 0o644)
    except Exception:
        pass

    return added


def main() -> int:
    root = Path(__file__).parent
    inventory_path = root / 'inventory.ini'

    try:
        hosts = load_hosts(inventory_path)
    except SystemExit:
        # load_hosts may sys.exit on inventory errors; surface a cleaner message
        print("Failed to load inventory; ensure inventory.ini exists and ansible-inventory is available", file=sys.stderr)
        return 2
    except Exception as e:
        print(f"Failed to load hosts: {e}", file=sys.stderr)
        return 2

    if not hosts:
        print("No hosts found in inventory; nothing to do.")
        return 0

    # hosts is expected as list of (name, ip)
    added = update_known_hosts(hosts)
    print(f"Done — added {added} host key(s) to {KNOWN_HOSTS_PATH}")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
