#!/usr/bin/env bash
# setup-api.sh - LLDPq-IB setup/onboarding helper

source "$(dirname "$0")/auth-guard.sh"
require_admin

source /etc/lldpq.conf 2>/dev/null || true
LLDPQ_DIR="${LLDPQ_DIR:-/home/lldpq/lldpq}"
LLDPQ_USER="${LLDPQ_USER:-lldpq}"
WEB_ROOT="${WEB_ROOT:-/var/www/html}"
ACTION="${QUERY_STRING#*action=}"
ACTION="${ACTION%%&*}"

echo "Content-Type: application/json"
echo ""

case "$ACTION" in
    status)
        export LLDPQ_DIR LLDPQ_USER WEB_ROOT LLDPQ_DEMO UFM_URL UFM_TOKEN UFM_VERIFY_TLS
        python3 <<'PY'
import json, os, subprocess
try:
    import yaml
except Exception:
    yaml = None

lldpq_dir = os.environ.get('LLDPQ_DIR', '/home/lldpq/lldpq')
web_root = os.environ.get('WEB_ROOT', '/var/www/html')
user = os.environ.get('LLDPQ_USER', 'lldpq')

def exists(*parts):
    return os.path.exists(os.path.join(*parts))

devices_path = os.path.join(lldpq_dir, 'devices.yaml')
devices_count = 0
roles = {}
if yaml and os.path.exists(devices_path):
    try:
        data = yaml.safe_load(open(devices_path)) or {}
        for ip, val in (data.get('devices') or {}).items():
            if ip in ('defaults', 'endpoint_hosts'):
                continue
            if isinstance(val, str):
                parts = val.strip().split()
                role = next((p[1:] for p in parts[1:] if p.startswith('@')), 'switch')
            elif isinstance(val, dict):
                role = val.get('role', 'switch')
            else:
                role = 'switch'
            devices_count += 1
            roles[role] = roles.get(role, 0) + 1
    except Exception:
        pass

home = os.path.expanduser(f'~{user}')
pub_candidates = [
    os.path.join(home, '.ssh', 'id_ed25519.pub'),
    os.path.join(home, '.ssh', 'id_rsa.pub'),
]
ssh_pub = ''
key_file = ''
for p in pub_candidates:
    try:
        r = subprocess.run(['sudo', '-u', user, 'cat', p], capture_output=True, text=True, timeout=4)
        if r.returncode == 0 and r.stdout.strip():
            ssh_pub = r.stdout.strip()
            key_file = p
            break
    except Exception:
        pass

mr = os.path.join(lldpq_dir, 'monitor-results')
topo = os.path.join(mr, 'ib_topology.json')
health = os.path.join(mr, 'fabric_health.json')
assets = os.path.join(web_root, 'assets.ini')

out = {
    'success': True,
    'demo_mode': os.environ.get('LLDPQ_DEMO', 'false').lower() == 'true',
    'devices_yaml': {
        'exists': os.path.exists(devices_path),
        'path': devices_path,
        'count': devices_count,
        'roles': roles,
    },
    'ssh_key': {
        'exists': bool(ssh_pub),
        'key_file': key_file,
        'public_key': ssh_pub,
    },
    'monitoring': {
        'has_topology': os.path.exists(topo),
        'has_health': os.path.exists(health),
        'has_assets': os.path.exists(assets),
        'topology_mtime': int(os.path.getmtime(topo)) if os.path.exists(topo) else 0,
        'health_mtime': int(os.path.getmtime(health)) if os.path.exists(health) else 0,
    },
    'ufm': {
        'configured': bool(os.environ.get('UFM_URL', '').strip()),
        'url': os.environ.get('UFM_URL', ''),
        'token_set': bool(os.environ.get('UFM_TOKEN', '').strip()),
        'verify_tls': os.environ.get('UFM_VERIFY_TLS', 'false').lower() == 'true',
    },
}
print(json.dumps(out))
PY
        ;;

    push-ssh-key)
        # POST { "password": "<switch admin password>" }
        # Authorizes the collector's PUBLIC key on every switch in devices.yaml
        # using the interactive enable-mode CLI (MLNX-OS admin is CLI-only, so
        # exec/`ssh host "cmd"` is rejected). Runs the push as www-data via
        # sshpass (password auth, no key needed) and verifies key auth as lldpq.
        if [ "${LLDPQ_DEMO:-false}" = "true" ]; then
            echo '{"success": false, "error": "SSH key push is disabled in LLDPQ_DEMO=true mode."}'
            exit 0
        fi
        read -r POST_DATA
        export POST_DATA LLDPQ_DIR LLDPQ_USER
        python3 <<'PY'
import json, os, subprocess
from concurrent.futures import ThreadPoolExecutor

try:
    body = json.loads(os.environ.get('POST_DATA') or '{}')
except Exception:
    body = {}
password = body.get('password', '')
if not password:
    print(json.dumps({'success': False, 'error': 'Switch admin password is required.'}))
    raise SystemExit

lldpq_dir = os.environ.get('LLDPQ_DIR', '/home/lldpq/lldpq')
user = os.environ.get('LLDPQ_USER', 'lldpq')

# Collector public + private key (read pub as lldpq via the allowed sudo cat).
pub, priv = '', ''
for base in ('id_ed25519', 'id_rsa'):
    p = f'/home/{user}/.ssh/{base}.pub'
    r = subprocess.run(['sudo', '-u', user, 'cat', p], capture_output=True, text=True)
    if r.returncode == 0 and r.stdout.strip():
        pub, priv = r.stdout.strip(), f'/home/{user}/.ssh/{base}'
        break
if not pub:
    print(json.dumps({'success': False, 'error': 'No collector SSH key yet. Click "Generate key" first.'}))
    raise SystemExit

try:
    import yaml
    data = yaml.safe_load(open(os.path.join(lldpq_dir, 'devices.yaml'))) or {}
except Exception as e:
    print(json.dumps({'success': False, 'error': f'Cannot read devices.yaml: {e}'}))
    raise SystemExit

defaults = data.get('defaults', {})
duser = defaults.get('username', 'admin')
devs = []
for ip, val in (data.get('devices') or {}).items():
    if isinstance(val, str):
        parts = val.strip().split()
        host = parts[0] if parts else ip
        u = duser
    elif isinstance(val, dict):
        host = val.get('hostname', ip)
        u = val.get('username', duser)
    else:
        continue
    devs.append((ip, u, host))

def push(dev):
    ip, u, host = dev
    cli = (f'enable\nconfigure terminal\n'
           f'ssh client user {u} authorized-key sshv2 "{pub}"\n'
           f'write memory\nexit\nexit\n')
    # Push (password auth via sshpass -e; SSHPASS keeps it out of argv).
    subprocess.run(
        ['timeout', '35', 'sshpass', '-e', 'ssh', '-tt',
         '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null',
         '-o', 'PubkeyAuthentication=no',
         '-o', 'PreferredAuthentications=keyboard-interactive,password',
         '-o', 'ConnectTimeout=10', '-o', 'LogLevel=ERROR', f'{u}@{ip}'],
        input=cli, capture_output=True, text=True,
        env={**os.environ, 'SSHPASS': password})
    # Verify key auth now works (as lldpq, using its private key).
    v = subprocess.run(
        ['sudo', '-u', user, 'timeout', '15', 'ssh', '-i', priv, '-tt',
         '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no',
         '-o', 'UserKnownHostsFile=/dev/null', '-o', 'ConnectTimeout=10',
         '-o', 'LogLevel=ERROR', f'{u}@{ip}'],
        input='exit\n', capture_output=True, text=True)
    ok = v.returncode == 0 and 'Permission denied' not in (v.stdout + v.stderr)
    return {'host': host, 'ip': ip, 'ok': ok}

results = sorted(ThreadPoolExecutor(max_workers=10).map(push, devs),
                 key=lambda r: r['host'])
ok = sum(1 for r in results if r['ok'])
print(json.dumps({'success': True, 'results': results,
                  'ok_count': ok, 'fail_count': len(results) - ok, 'total': len(results)}))
PY
        ;;

    queue-collection)
        if [ "${LLDPQ_DEMO:-false}" = "true" ]; then
            echo '{"success": false, "error": "Collection is disabled in LLDPQ_DEMO=true mode so fake data stays static."}'
            exit 0
        fi
        date +%s > /tmp/.assets_web_trigger 2>/dev/null || true
        date +%s > /tmp/.monitor_web_trigger 2>/dev/null || true
        echo '{"success": true, "message": "Collection queued. lldpq-trigger will run ib-assets.sh and ib-monitor.sh within about one minute."}'
        ;;

    *)
        echo "{\"success\": false, \"error\": \"Unknown setup action: ${ACTION}\"}"
        ;;
esac
