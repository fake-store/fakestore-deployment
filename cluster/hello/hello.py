import sys
import subprocess
import json
import shutil
from pathlib import Path


def _load_inventory_json(inventory_path):
    """Try to load inventory via `ansible-inventory --list -i INVENTORY` and return parsed JSON or None on failure."""
    try:
        ai = shutil.which('ansible-inventory')
        if not ai:
            return None
        p = subprocess.run([ai, '--list', '-i', str(inventory_path)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
        if p.returncode != 0:
            return None
        return json.loads(p.stdout)
    except Exception:
        return None


def run_hello(tmp, log_path, kubeconfig_path, inventory_path):
    # manifest lives next to this script (hello/hello-ds.yml)
    manifest_path = Path(__file__).resolve().parent / 'hello-ds.yml'

    if not manifest_path.exists():
        print(f"Manifest not found: {manifest_path}")
        return 2

    # If kubeconfig doesn't exist, attempt to fetch it by running the diag playbook
    if not kubeconfig_path.exists():
        print('kubeconfig not found locally')
        sys.exit(0)

    # Try to adjust kubeconfig server address if it points to localhost
    kube_to_use_path = kubeconfig_path
    try:
        if kubeconfig_path.exists():
            text = kubeconfig_path.read_text(encoding='utf-8')
            # Find a server: line and if it contains 127.0.0.1 or localhost, replace with server IP from inventory
            if '127.0.0.1' in text or 'localhost' in text:
                server_ip = None
                inv = _load_inventory_json(inventory_path)
                if not inv:
                    print('ansible-inventory not available or failed; please install ansible and ensure ansible-inventory is on PATH')
                    return 4
                hostvars = inv.get('_meta', {}).get('hostvars', {})
                # look for host with role == server
                for hn, hv in hostvars.items():
                    try:
                        if hv.get('role') == 'server' and hv.get('ansible_host'):
                            server_ip = hv.get('ansible_host')
                            break
                    except Exception:
                        continue

                if server_ip:
                    new_text = text
                    # replace common localhost server patterns
                    new_text = new_text.replace('https://127.0.0.1:6443', f'https://{server_ip}:6443')
                    new_text = new_text.replace('https://localhost:6443', f'https://{server_ip}:6443')
                    # write adjusted kubeconfig to a temp file to avoid overwriting original
                    kube_adj_path = tmp / 'kubeconfig-hello'
                    kube_adj_path.write_text(new_text, encoding='utf-8')
                    kube_to_use_path = kube_adj_path
                    print(f'Adjusted kubeconfig server to https://{server_ip}:6443 and will use {kube_to_use_path}')
                else:
                    print('Could not determine server IP from inventory; using existing kubeconfig (may point to localhost)')
    except Exception as e:
        print('Warning: failed to adjust kubeconfig:', e)

    # Build kubectl base command
    kubectl_cmd = ['kubectl']
    if kube_to_use_path.exists():
        kubectl_cmd += ['--kubeconfig', str(kube_to_use_path)]

    apply_cmd = kubectl_cmd + ['apply', '-f', str(manifest_path)]
    rollout_cmd = kubectl_cmd + ['rollout', 'status', 'daemonset/hello-node', '--timeout=120s', '-n', 'default']

    with log_path.open('w', encoding='utf-8') as lf:
        lf.write(f"Applying manifest: {manifest_path}\n")
        lf.flush()
        try:
            p = subprocess.run(apply_cmd, check=False, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            print(p.stdout)
            lf.write(p.stdout or '')
            lf.flush()
            rc = p.returncode
            if rc != 0:
                print(f"kubectl apply failed (rc={rc}). See {log_path}")
                return rc

            p2 = subprocess.run(rollout_cmd, check=False, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            print(p2.stdout)
            lf.write(p2.stdout or '')
            lf.flush()
            if p2.returncode != 0:
                print(f"rollout status failed (rc={p2.returncode}). See {log_path}")
                return p2.returncode

            # If rollout succeeded, test HTTP on each node from ansible-inventory
            nodes = []
            inv = _load_inventory_json(inventory_path)
            if not inv:
                print('ansible-inventory not available or failed; please install ansible and ensure ansible-inventory is on PATH')
                return 4
            hostvars = inv.get('_meta', {}).get('hostvars', {})
            pis = inv.get('pis', {}).get('hosts', [])
            if pis:
                for name in pis:
                    ip = hostvars.get(name, {}).get('ansible_host')
                    if ip:
                        nodes.append((name, ip))
            else:
                # fallback: iterate hostvars and pick entries with ansible_host defined
                for name, hv in hostvars.items():
                    ip = hv.get('ansible_host')
                    if ip:
                        nodes.append((name, ip))

            if not nodes:
                print('No nodes found in inventory via ansible-inventory')
                return 5

            # Save curl results and build URLs
            curl_lines = []
            urls = []
            for name, ip in nodes:
                url = f"http://{ip}:5678"
                urls.append(url)
                cmd = ['curl', '-sS', '--max-time', '5', url]
                try:
                    r = subprocess.run(cmd, check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                    out = r.stdout.strip() or r.stderr.strip()
                    curl_lines.append(f"{name} ({ip}): {out}")
                    print(f"{name} ({ip}): {out}")
                    lf.write(f"{name} ({ip}): {out}\n")
                except Exception as e:
                    curl_lines.append(f"{name} ({ip}): ERROR {e}")
                    lf.write(f"{name} ({ip}): ERROR {e}\n")

            # write curl results file
            with (tmp / 'curl-results.txt').open('w', encoding='utf-8') as cf:
                cf.write('\n'.join(curl_lines))

            # write urls file and print a concise summary for the user
            with (tmp / 'hello-urls.txt').open('w', encoding='utf-8') as uf:
                uf.write('\n'.join(urls) + '\n')

            print('\nHello deployment completed. Instance URLs:')
            for u in urls:
                print('  ', u)
            print('\nCurl results written to', tmp / 'curl-results.txt')
            lf.write('\nHello deployment and checks completed.\n')
            lf.write('URLs:\n')
            for u in urls:
                lf.write(u + '\n')
            lf.flush()
            return 0
        except FileNotFoundError as e:
            msg = f"kubectl not found: {e}. Install kubectl or ensure it's on PATH"
            print(msg)
            lf.write(msg + '\n')
            return 3
