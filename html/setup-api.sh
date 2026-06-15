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
# Prefer RSA: MLNX-OS authorized-key sshv2 honors RSA; ed25519 is not accepted on
# some versions. Show/push the RSA key so manual paste + auto-push both work.
pub_candidates = [
    os.path.join(home, '.ssh', 'id_rsa.pub'),
    os.path.join(home, '.ssh', 'id_ed25519.pub'),
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
        # Authorizes the collector key on every switch in devices.yaml. The push
        # itself is done by send-key.sh running AS lldpq (sudo) -- MLNX-OS admin
        # is CLI-only so send-key.sh drives an interactive enable-mode session,
        # and running as lldpq means it uses the collector key + sshpass reliably.
        if [ "${LLDPQ_DEMO:-false}" = "true" ]; then
            echo '{"success": false, "error": "SSH key push is disabled in LLDPQ_DEMO=true mode."}'
            exit 0
        fi
        read -r POST_DATA
        PW=$(printf '%s' "$POST_DATA" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("password",""))' 2>/dev/null)
        if [ -z "$PW" ]; then
            echo '{"success": false, "error": "Switch admin password is required."}'
            exit 0
        fi
        OUT=$(sudo -u "$LLDPQ_USER" -H "$LLDPQ_DIR/send-key.sh" -p "$PW" 2>&1)
        export OUT
        python3 <<'PY'
import os, json, re
out = os.environ.get('OUT', '')
results = []
for m in re.finditer(r'\[(OK|FAIL)\]\s+(\S+)\s+\(([^)]+)\)', out):
    results.append({'host': m.group(2), 'ip': m.group(3), 'ok': m.group(1) == 'OK'})
ok = sum(1 for r in results if r['ok'])
if not results:
    print(json.dumps({'success': False,
                      'error': 'send-key.sh produced no results',
                      'raw': out[-600:]}))
else:
    print(json.dumps({'success': True, 'results': results,
                      'ok_count': ok, 'fail_count': len(results) - ok,
                      'total': len(results)}))
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
