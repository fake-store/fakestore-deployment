#!/usr/bin/env python3
import argparse
import subprocess
import sys
import shutil
from pathlib import Path

ROOT = Path(__file__).parent
INVENTORY_PATH = ROOT / 'inventory.ini'

PLAYBOOKS = {
    'setup': ROOT / 'cluster_setup_playbook.yml',
    'diag': ROOT / 'cluster_diag_playbook.yml'
}


def ensure_tmp_dir():
    tmp = ROOT / 'tmp'
    tmp.mkdir(parents=True, exist_ok=True)
    return tmp


def ensure_ansible_available():
    if shutil.which('ansible-playbook'):
        return True
    # try to install for the user via pip
    print('ansible-playbook not found. Attempting to install ansible (user) via pip...')
    try:
        subprocess.run([sys.executable, '-m', 'pip', 'install', '--user', 'ansible'], check=True)
    except subprocess.CalledProcessError:
        print('Failed to install ansible automatically. Please install Ansible manually.')
        return False
    # After pip install, the script's PATH may not include ~/.local/bin; try common path
    local_bin = Path.home() / '.local' / 'bin'
    if str(local_bin) not in subprocess.os.environ.get('PATH', ''):
        subprocess.os.environ['PATH'] = str(local_bin) + ':' + subprocess.os.environ.get('PATH', '')
    return shutil.which('ansible-playbook') is not None


def run_playbook(name):
    playbook = PLAYBOOKS.get(name)
    if not playbook or not playbook.exists():
        print(f"Playbook for '{name}' not found: {playbook}")
        return 2

    if not ensure_ansible_available():
        return 3

    tmp = ensure_tmp_dir()
    log_path = tmp / f"{name}.log"

    cmd = [
        'ansible-playbook',
        '-i', str(INVENTORY_PATH),
        str(playbook)
    ]

    print('Running:', ' '.join(cmd))
    # Stream output to both terminal and log file in real time
    with log_path.open('w', encoding='utf-8') as lf:
        lf.write(f"Running: {' '.join(cmd)}\n\n")
        lf.flush()
        try:
            # Use line-buffered text mode to stream output
            p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
            try:
                # Iterate over output lines as they arrive
                for line in p.stdout:
                    # print to terminal
                    sys.stdout.write(line)
                    sys.stdout.flush()
                    # write to log
                    lf.write(line)
                    lf.flush()
            except KeyboardInterrupt:
                p.terminate()
                p.wait()
                lf.write('\n[Interrupted]\n')
                lf.flush()
                print('\nExecution interrupted by user')
                return 130
            rc = p.wait()
            lf.write(f"\nPlaybook exited with code: {rc}\n")
            lf.flush()
            print(f"Playbook '{name}' finished with exit code {rc}; log: {log_path}")
            return rc
        except FileNotFoundError:
            msg = 'ansible-playbook not found after install attempt. Please ensure Ansible is installed.'
            print(msg)
            lf.write(msg + '\n')
            return 3


def run_hello():
    tmp = ensure_tmp_dir()
    try:
        from hello.hello import run_hello
    except ImportError as e:
        print(f"Failed to import hello module: {e}")
        return 1
    rc = run_hello(
        tmp=tmp,
        log_path=tmp / 'hello.log',
        kubeconfig_path=tmp / 'kubeconfig-pi1',
        inventory_path=INVENTORY_PATH
    )
    return rc


def main():
    parser = argparse.ArgumentParser(description='k3s playbook runner')
    # Allow 'setup','diag','hello'
    parser.add_argument('cmd', choices=['setup', 'diag', 'hello'], help='command to run')
    args = parser.parse_args()

    if args.cmd == 'hello':
        rc = run_hello()
    else:
        rc = run_playbook(args.cmd)

    if rc == 0:
        print(f"{args.cmd} completed successfully")
    else:
        print(f"{args.cmd} failed with exit code {rc}")
    sys.exit(rc)


if __name__ == '__main__':
    main()
